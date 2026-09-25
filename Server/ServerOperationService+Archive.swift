import DetoursProcess
import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func prepareArchive(_ identity: OperationRequestIdentity, password: String?) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let accepted = try journal.read(identity.id)
        if let receipt = accepted.receipt, [.readyToCommit, .committed, .terminal].contains(receipt.phase) { return receipt }
        guard accepted.receipt == nil, let intent = accepted.intent, intent.action == .archiveCreate,
              let destination = intent.destination else { throw OperationContractError.invalidReceipt }
        var preparation: ServerPayloadPreparation?
        do {
            let format: SevenZipArchiveWriter.Format
            switch intent.archiveFormat {
            case ServerArchiveFormat.sevenZ.rawValue: format = .sevenZ
            case ServerArchiveFormat.zip.rawValue: format = .zip
            default: throw OperationFilesystemError.unsupported
            }
            guard let encrypted = intent.archiveEncrypted, encrypted == (password?.isEmpty == false) else {
                throw OperationContractError.intentMismatch
            }
            guard password?.contains("\0") != true else { throw SevenZipArchiveError.invalidEntry }
            if format == .zip, let password, password.utf8.count > 80 {
                throw ArchiveOperationsError.invalidPassword("ZIP passwords are limited to 80 UTF-8 bytes")
            }
            try requirePreparationDestination(intent)
            let source = try await archiveSources(intent, identity: identity, ownership: ownership, measuredBefore: 0)
            let target = try resolve(destination)
            guard !(source.manifest.entries + source.inputs.entries).contains(where: {
                $0.observation.kind == .directory && $0.observation.identity == target.directory.identity
            }) else { throw OperationFilesystemError.unsupported }
            let entries = try archiveEntries(source, id: identity.id)
            try journal.recordManifests(identity.id, source: source.manifest, payload: nil, archiveInputs: source.inputs, ownership: ownership)
            let allocated = try await allocatePreparation(identity, target: target.directory, ownership: ownership)
            preparation = allocated
            let output = try await createArchiveOutput(allocated, identity: identity, ownership: ownership)
            let progress = ServerArchiveProgress(service: self, identity: identity, ownership: ownership,
                                                 measuredBefore: source.measuredBytes)
            do {
                try await writeArchive(entries, output: output, password: password, format: format, progress: progress)
                try output.close()
            } catch {
                try output.close()
                throw error
            }
            let payload = try await treeCopyManifest(allocated.payload, identity: identity, ownership: ownership,
                                                     measuredBefore: progress.measured)
            let (hashed, overflow) = progress.measured.addingReportingOverflow(payload.proof.byteCount)
            guard !overflow else { throw OperationFilesystemError.unsupported }
            let finalSource = try await archiveSources(intent, identity: identity, ownership: ownership, measuredBefore: hashed)
            guard source.manifest == finalSource.manifest, source.root == finalSource.root,
                  source.inputs == finalSource.inputs, source.locations == finalSource.locations,
                  let observed = payload.entries.first?.observation, observed.kind == .file,
                  let hash = observed.sha256 else { throw OperationFilesystemError.identityChanged }
            if let expected = intent.payloadProof {
                guard expected == OperationContentProof(byteCount: observed.byteCount, sha256: hash) else {
                    throw OperationContractError.invalidReceipt
                }
            }
            try allocated.workspace.validateManifest(payload, root: Data("payload".utf8))
            try journal.recordManifests(identity.id, source: source.manifest, payload: payload, archiveInputs: source.inputs, ownership: ownership)
            let (measured, finalOverflow) = hashed.addingReportingOverflow(finalSource.measuredBytes)
            guard !finalOverflow else { throw OperationFilesystemError.unsupported }
            let ready = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1, phase: .readyToCommit, outcome: .running,
                contentVerified: true, preparedPayload: .init(location: allocated.payload, observation: observed),
                measuredBytes: measured, recovery: [
                    .init(identity: allocated.workspace.record.root.identity, purpose: .scratch, original: nil,
                          knownLocation: allocated.location, possibleLocations: [allocated.location]),
                    .init(identity: observed.identity, purpose: .scratch, original: nil,
                          knownLocation: allocated.payload, possibleLocations: [allocated.payload]),
                ]
            )
            try journal.record(ready, ownership: ownership)
            return ready
        } catch {
            try await failPreparation(identity, preparation: preparation, ownership: ownership, failure: error)
            throw error
        }
    }

    private func createArchiveOutput(_ preparation: ServerPayloadPreparation, identity: OperationRequestIdentity,
                                     ownership: OperationJournal.Ownership) async throws -> FileHandle {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
        let output = try preparation.workspace.createFile(named: Data("payload".utf8))
        do {
            try journal.recordWorkspace(preparation.workspace.record, ownership: ownership)
            return output
        } catch {
            try output.close()
            throw error
        }
    }

    private func writeArchive(_ entries: [SevenZipArchiveWriter.Entry], output: FileHandle, password: String?, format: SevenZipArchiveWriter.Format,
                              progress: ServerArchiveProgress) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try SevenZipArchiveWriter.create(entries: entries, output: output, password: password, format: format) { try progress.report($0) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class ServerArchiveProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let service: ServerOperationService
    private let identity: OperationRequestIdentity
    private let ownership: OperationJournal.Ownership
    private let measuredBefore: UInt64
    private let clock = ContinuousClock()
    private var reported: ContinuousClock.Instant
    private var completed: UInt64

    init(service: ServerOperationService, identity: OperationRequestIdentity,
         ownership: OperationJournal.Ownership, measuredBefore: UInt64) {
        self.service = service
        self.identity = identity
        self.ownership = ownership
        self.measuredBefore = measuredBefore
        completed = measuredBefore
        reported = clock.now
    }

    var measured: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func report(_ bytes: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard try !service.journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
        let (total, overflow) = measuredBefore.addingReportingOverflow(bytes)
        guard !overflow else { throw OperationFilesystemError.unsupported }
        completed = total
        if clock.now - reported >= .seconds(5) {
            try service.recordTreeProgress(identity, measured: total, ownership: ownership)
            reported = clock.now
        }
    }
}
