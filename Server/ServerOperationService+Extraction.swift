import DetoursProcess
import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func prepareArchiveExtraction(_ identity: OperationRequestIdentity, password: String?) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let accepted = try journal.read(identity.id)
        if let receipt = accepted.receipt, [.readyToCommit, .committed, .terminal].contains(receipt.phase) { return receipt }
        guard accepted.receipt == nil, let intent = accepted.intent, intent.action == .archiveExtract,
              intent.sources.count == 1, intent.sourceObservations.count == 1, let destination = intent.destination else {
            throw OperationContractError.invalidReceipt
        }
        var preparation: ServerPayloadPreparation?
        do {
            let format: SevenZipArchiveWriter.Format
            switch intent.archiveFormat {
            case ServerArchiveFormat.sevenZ.rawValue: format = .sevenZ
            case ServerArchiveFormat.zip.rawValue: format = .zip
            case ServerArchiveFormat.tarGz.rawValue: format = .gzip
            case ServerArchiveFormat.tarBz2.rawValue: format = .bzip2
            case ServerArchiveFormat.tarXz.rawValue: format = .xz
            default: throw OperationFilesystemError.unsupported
            }
            guard let encrypted = intent.archiveEncrypted, encrypted == (password?.isEmpty == false), password?.contains("\0") != true else {
                throw OperationContractError.intentMismatch
            }
            try requirePreparationDestination(intent)
            let source = try await treeCopyManifest(intent.sources[0], identity: identity, ownership: ownership, measuredBefore: 0)
            guard let observed = source.entries.first?.observation, observed.kind == .file,
                  observed.identity == intent.sourceObservations[0].identity, observed.version == intent.sourceObservations[0].version,
                  intent.sourceObservations[0].sha256 == nil || observed.sha256 == intent.sourceObservations[0].sha256 else {
                throw OperationFilesystemError.identityChanged
            }
            try journal.recordManifests(identity.id, source: source, payload: nil, ownership: ownership)
            let allocated = try await allocatePreparation(identity, target: resolve(destination).directory, ownership: ownership)
            preparation = allocated
            var reader = ServerArchiveExtractionReader(service: self, identity: identity, ownership: ownership,
                                                       input: .init(location: intent.sources[0], observation: observed), format: format, password: password)
            var measured = source.proof.byteCount
            var intermediate: OperationManifest?
            if [.gzip, .bzip2, .xz].contains(format) {
                guard !encrypted else { throw ArchiveOperationsError.invalidPassword("TAR archives do not support passwords") }
                let decoded = try await reader.decompressTar(into: allocated, measuredBefore: measured)
                intermediate = decoded.manifest
                measured = decoded.measured
                reader = decoded.reader
            }
            let listed = try await reader.read(measuredBefore: measured)
            measured = listed.measured
            let plan = try ServerArchiveExtractionPlan(listed.members)
            try await allocateExtractionMembers(plan, preparation: allocated, identity: identity, ownership: ownership)
            let extracted = try await reader.read(measuredBefore: measured, output: { member in
                guard plan.members.indices.contains(Int(member.index)), plan.members[Int(member.index)] == member,
                      let name = plan.outputs[member.index] else { throw OperationFilesystemError.identityChanged }
                return try allocated.workspace.openEmptyFileForWriting(named: name)
            })
            guard extracted.members == plan.members else { throw OperationFilesystemError.identityChanged }
            measured = extracted.measured
            try await finishExtractionMembers(plan, preparation: allocated, identity: identity, ownership: ownership)
            let payload = try await treeCopyManifest(allocated.payload, identity: identity, ownership: ownership, measuredBefore: measured)
            measured = try extractionMeasured(measured, adding: payload.proof.byteCount)
            if let intermediate {
                let current = try await treeCopyManifest(reader.input.location, identity: identity, ownership: ownership, measuredBefore: measured)
                guard current == intermediate else { throw OperationFilesystemError.identityChanged }
                try allocated.workspace.validateManifest(current, root: Data("archive.tar".utf8))
                measured = try extractionMeasured(measured, adding: current.proof.byteCount)
            }
            let finalSource = try await treeCopyManifest(intent.sources[0], identity: identity, ownership: ownership, measuredBefore: measured)
            guard finalSource == source, let root = payload.entries.first?.observation,
                  intent.payloadProof == nil || intent.payloadProof == payload.proof else { throw OperationFilesystemError.identityChanged }
            measured = try extractionMeasured(measured, adding: finalSource.proof.byteCount)
            try allocated.workspace.validateManifest(payload, root: Data("payload".utf8))
            try journal.recordManifests(identity.id, source: source, payload: payload, ownership: ownership)
            let verified = OperationObservation(identity: root.identity, kind: root.kind, version: root.version, byteCount: root.byteCount,
                                                sha256: root.kind == .file ? root.sha256 : payload.proof.sha256,
                                                linkTarget: root.linkTarget, contentVersion: root.contentVersion)
            let ready = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1, phase: .readyToCommit, outcome: .running,
                contentVerified: true, preparedPayload: .init(location: allocated.payload, observation: verified), measuredBytes: measured,
                recovery: [
                    .init(identity: allocated.workspace.record.root.identity, purpose: .scratch, original: nil,
                          knownLocation: allocated.location, possibleLocations: [allocated.location]),
                    .init(identity: root.identity, purpose: .scratch, original: nil,
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

    func extractionMeasured(_ before: UInt64, adding bytes: UInt64) throws -> UInt64 {
        let (total, overflow) = before.addingReportingOverflow(bytes)
        guard !overflow else { throw OperationFilesystemError.unsupported }
        return total
    }
}
