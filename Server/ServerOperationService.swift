import Foundation
import RemoteOperationSupport

struct ServerOperationService: Sendable {
    let journal: OperationJournal
    let trashStore: ServerOperationTrash
    let afterTrashMove: (@Sendable (OperationLocation) throws -> Void)?

    init(root: URL, account: OperationAccount, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         afterTrashMove: (@Sendable (OperationLocation) throws -> Void)? = nil) async throws {
        journal = try await OperationJournal(root: root, account: account)
        trashStore = ServerOperationTrash(homeDirectory: homeDirectory, account: account)
        self.afterTrashMove = afterTrashMove
    }

    func accept(_ identity: OperationRequestIdentity, intent: OperationIntent) async throws -> OperationJournal.Snapshot {
        try validate(identity)
        guard identity.id == intent.id,
              try OperationContentProof.data(intent.canonicalData()).sha256 == identity.intentDigest else {
            throw OperationContractError.intentMismatch
        }
        let ownership = try await journal.acquireItem(identity.id)
        return try journal.accept(intent, digest: identity.intentDigest, ownership: ownership)
    }

    func status(_ identity: OperationRequestIdentity) throws -> OperationJournal.Snapshot {
        try reconcile(readSnapshot(identity))
    }

    private func readSnapshot(_ identity: OperationRequestIdentity) throws -> OperationJournal.Snapshot {
        try validate(identity)
        let snapshot = try journal.read(identity.id)
        guard snapshot.intentDigest == identity.intentDigest else { throw OperationContractError.intentMismatch }
        return snapshot
    }

    func cancel(_ identity: OperationRequestIdentity) throws {
        _ = try readSnapshot(identity)
        try journal.requestCancellation(identity.id)
    }

    func acknowledge(_ identity: OperationRequestIdentity, retainingUndo: Bool) async throws {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        try journal.acknowledge(identity.id, retainingUndo: retainingUndo, ownership: ownership)
    }

    func prepareUpload(_ identity: OperationRequestIdentity, contents: Data) async throws -> OperationReceipt {
        guard contents.count <= 1_048_576 else { throw OperationFilesystemError.unsupported }
        return try await prepare(identity, input: .contents(contents))
    }

    func prepareStream(_ identity: OperationRequestIdentity, input: FileHandle) async throws -> OperationReceipt {
        try await prepare(identity, input: .stream(input))
    }

    private func prepare(_ identity: OperationRequestIdentity, input: ServerOperationInput) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let accepted = try journal.read(identity.id)
        if let receipt = accepted.receipt, [.payloadReceived, .readyToCommit, .committed, .terminal].contains(receipt.phase) { return receipt }
        guard let proof = accepted.intent?.payloadProof else { throw OperationContractError.invalidReceipt }
        return try await prepareOwned(accepted, ownership: ownership, input: input, proof: proof)
    }

    func prepareOwned(_ accepted: OperationJournal.Snapshot, ownership: OperationJournal.Ownership,
                      input: ServerOperationInput, proof: OperationContentProof) async throws -> OperationReceipt {
        let preparation: UploadPreparation
        do {
            preparation = try await allocateUpload(accepted, ownership: ownership, proof: proof)
        } catch {
            try recordUnallocatedFailure(accepted.id, ownership: ownership, failure: error)
            throw error
        }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try self.receiveUpload(preparation, ownership: ownership, input: input)
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } catch {
            let original = error
            let commit = try await journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            try preparation.workspace.removeScratch()
            let current = try journal.read(accepted.id)
            let unchanged = OperationReceipt(
                id: accepted.id, account: journal.account, epoch: journal.epoch, intentDigest: accepted.intentDigest,
                revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal, outcome: .failedUnchanged,
                failure: String(describing: original)
            )
            try journal.record(unchanged, ownership: ownership)
            throw original
        }
    }

    func commit(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        let snapshot = try status(identity)
        if let result = snapshot.receipt, [.committed, .terminal].contains(result.phase) { return result }
        let publication: OperationReceipt
        do {
            publication = try await OperationPublication.publish(journal: journal, id: identity.id, ownership: ownership)
        } catch {
            try await recordUnstartedCommitFailure(identity, ownership: ownership, failure: error)
            throw error
        }
        let published = try await handoffReplacement(publication, ownership: ownership)
        guard let record = snapshot.workspace, let destination = snapshot.intent?.destination else { return published }
        var recovery = published.recovery
        var failure = published.failure
        do {
            let cleanup = try await journal.acquireCommit()
            defer { withExtendedLifetime(cleanup) {} }
            let parent = try OperationDirectory(path: Self.parentPath(destination))
            let workspace = try OperationWorkspace(parent: parent, record: record)
            try workspace.removeScratch()
            recovery.removeAll { $0.purpose == .scratch && $0.identity == record.root.identity }
        } catch { failure = [failure, "Scratch cleanup: \(error)"].compactMap { $0 }.joined(separator: "; ") }
        let result = OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: published.revision + 1, phase: published.outcome == .committed ? .terminal : .committed,
            outcome: published.outcome, effects: published.effects, sourceDisposition: published.sourceDisposition,
            contentVerified: published.contentVerified, plannedPaths: published.plannedPaths,
            recovery: recovery, children: published.children, failure: failure
        )
        try journal.record(result, ownership: ownership)
        return result
    }

    // Created on one executor and consumed by one worker; no concurrent workspace access.
    private struct UploadPreparation: @unchecked Sendable {
        let accepted: OperationJournal.Snapshot
        let workspace: OperationWorkspace
        let output: FileHandle
        let receipt: OperationReceipt
        let proof: OperationContentProof
    }

    private func allocateUpload(_ accepted: OperationJournal.Snapshot,
                                ownership: OperationJournal.Ownership, proof: OperationContentProof) async throws -> UploadPreparation {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        guard try journal.read(accepted.id) == accepted, accepted.workspace == nil,
              accepted.receipt == nil || accepted.receipt?.phase == .preparing,
              let intent = accepted.intent, let destination = intent.destination,
              destination.account == journal.account,
              intent.payloadProof == nil || intent.payloadProof == proof,
              [.copy, .move, .editorUpload].contains(intent.action) else { throw OperationContractError.invalidReceipt }
        guard try !journal.cancellationRequested(intent.id) else { throw OperationContractError.cancelled }
        try requirePreparationDestination(intent)
        let parent = try OperationDirectory(path: Self.parentPath(destination))
        let name = OperationWorkspace.plannedName(for: intent.id)
        let planned = OperationLocation(account: journal.account, path: .unix(try parent.childPath(name)))
        let receipt = OperationReceipt(
            id: intent.id, account: journal.account, epoch: journal.epoch, intentDigest: accepted.intentDigest,
            revision: (accepted.receipt?.revision ?? 0) + 1, phase: .preparing, outcome: .running, plannedPaths: [planned]
        )
        try journal.record(receipt, ownership: ownership)
        let workspace = try OperationWorkspace(parent: parent, id: intent.id, plannedName: name)
        try journal.recordWorkspace(workspace.record, ownership: ownership)
        let payloadName = Data("payload".utf8)
        let output = try workspace.createFile(named: payloadName)
        try journal.recordWorkspace(workspace.record, ownership: ownership)
        return UploadPreparation(accepted: accepted, workspace: workspace, output: output, receipt: receipt, proof: proof)
    }

    private func receiveUpload(_ preparation: UploadPreparation, ownership: OperationJournal.Ownership,
                               input: ServerOperationInput) throws -> OperationReceipt {
        let accepted = preparation.accepted
        let expected = preparation.proof
        guard let intent = accepted.intent,
              let planned = preparation.receipt.plannedPaths?.first else { throw OperationContractError.invalidReceipt }
        let workspace = preparation.workspace
        let output = preparation.output
        let payloadName = Data("payload".utf8)
        var receipt = preparation.receipt
        var outputOpen = true
        defer { if outputOpen { try? output.close() } }
        var received: UInt64 = 0
        let measuredBefore = accepted.receipt?.measuredBytes ?? 0
        let clock = ContinuousClock()
        var lastProgress = clock.now
        func report(_ measured: UInt64) throws {
            guard clock.now - lastProgress >= .seconds(5) else { return }
            receipt = OperationReceipt(
                id: intent.id, account: journal.account, epoch: journal.epoch, intentDigest: accepted.intentDigest,
                revision: receipt.revision + 1, phase: .preparing, outcome: .running,
                plannedPaths: [planned], measuredBytes: measuredBefore + measured
            )
            try journal.record(receipt, ownership: ownership)
            lastProgress = clock.now
        }
        do {
            while true {
                guard try !journal.cancellationRequested(intent.id) else { throw OperationContractError.cancelled }
                let chunk = try input.next(offset: received, expected: expected.byteCount) {
                    try journal.cancellationRequested(intent.id)
                }
                if chunk.isEmpty { break }
                received += UInt64(chunk.count)
                guard received <= expected.byteCount else { throw OperationContractError.invalidReceipt }
                try output.write(contentsOf: chunk)
                try report(received)
            }
            guard received == expected.byteCount else { throw OperationContractError.invalidReceipt }
            try input.copyMetadata(to: output)
            try output.synchronize()
            try output.close()
            outputOpen = false
            let observation = try workspace.directory.proveFile(payloadName) { hashed in
                guard try !journal.cancellationRequested(intent.id) else { throw OperationContractError.cancelled }
                try report(received + hashed)
            }
            guard observation.sha256 == expected.sha256, observation.byteCount == expected.byteCount else {
                throw OperationContractError.invalidReceipt
            }
            try input.validateSource()
            let location = OperationLocation(account: journal.account, path: .unix(try workspace.directory.childPath(payloadName)))
            let recovery = [
                OperationRecoveryReference(identity: workspace.record.root.identity, purpose: .scratch,
                                           original: nil, knownLocation: planned, possibleLocations: [planned]),
                OperationRecoveryReference(identity: observation.identity, purpose: .scratch,
                                           original: nil, knownLocation: location, possibleLocations: [location]),
            ]
            receipt = OperationReceipt(
                id: intent.id, account: journal.account, epoch: journal.epoch, intentDigest: accepted.intentDigest,
                revision: receipt.revision + 1, phase: intent.treeProof == nil ? .readyToCommit : .payloadReceived, outcome: .running,
                contentVerified: true, preparedPayload: OperationEffect(location: location, observation: observation),
                measuredBytes: measuredBefore + received * 2, recovery: recovery
            )
            try journal.record(receipt, ownership: ownership)
            return receipt
        } catch {
            let original = error
            if outputOpen {
                try output.close()
                outputOpen = false
            }
            throw original
        }
    }

    private func validate(_ identity: OperationRequestIdentity) throws {
        guard identity.account == journal.account else { throw OperationContractError.identityMismatch }
        guard identity.epoch == journal.epoch else { throw OperationContractError.epochMismatch }
    }

    private static func parentPath(_ location: OperationLocation) throws -> Data {
        guard case .unix(let path) = location.path, path.first == 47,
              let slash = path.lastIndex(of: 47), slash < path.index(before: path.endIndex) else {
            throw OperationFilesystemError.invalidPath
        }
        return slash == path.startIndex ? Data([47]) : Data(path[..<slash])
    }
}
