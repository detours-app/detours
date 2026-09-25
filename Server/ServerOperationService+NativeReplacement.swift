import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func prepareNativeReplacement(_ identity: OperationRequestIdentity) async throws {
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let accepted = try journal.read(identity.id)
        if let receipt = accepted.receipt, [.readyToCommit, .committed, .terminal].contains(receipt.phase) { return }
        guard accepted.receipt == nil, let intent = accepted.intent,
              [.rename, .move].contains(intent.action), case .replace = intent.conflict,
              intent.sources.count == 1, intent.sourceObservations.count == 1,
              let destination = intent.destination else { throw OperationContractError.invalidReceipt }
        do {
            let expected = intent.sourceObservations[0]
            let observed = expected.kind == .file ? try await proveSource(intent, ownership: ownership) : expected
            let commit = try await journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
            let source = try resolve(intent.sources[0])
            let target = try resolve(destination)
            let current = try source.directory.observe(source.name)
            guard current.identity == observed.identity, current.version == observed.version,
                  current.kind == observed.kind, current.linkTarget == observed.linkTarget else {
                throw OperationFilesystemError.identityChanged
            }
            guard source.directory.identity.volume == target.directory.identity.volume,
                  intent.sources[0] != destination else { throw OperationFilesystemError.unsupported }
            let name = OperationWorkspace.plannedName(for: intent.id)
            let location = OperationLocation(account: journal.account, path: .unix(try target.directory.childPath(name)))
            let revision = (try journal.read(identity.id).receipt?.revision ?? 0) + 1
            try journal.record(OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: revision, phase: .preparing, outcome: .running, sourceDisposition: .present,
                plannedPaths: [location]
            ), ownership: ownership)
            let workspace = try OperationWorkspace(parent: target.directory, id: identity.id, plannedName: name)
            try journal.recordWorkspace(workspace.record, ownership: ownership)
            try journal.record(OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: revision + 1, phase: .readyToCommit, outcome: .running, sourceDisposition: .present,
                contentVerified: observed.sha256 != nil,
                preparedPayload: OperationEffect(location: intent.sources[0], observation: observed),
                plannedPaths: [location], recovery: [
                    OperationRecoveryReference(identity: observed.identity, purpose: .source, original: intent.sources[0],
                                               knownLocation: intent.sources[0], possibleLocations: [intent.sources[0]]),
                    OperationRecoveryReference(identity: workspace.record.root.identity, purpose: .scratch, original: nil,
                                               knownLocation: location, possibleLocations: [location]),
                ]
            ), ownership: ownership)
        } catch {
            let current = try journal.read(identity.id)
            if current.workspace == nil, current.receipt?.plannedPaths == nil {
                try journal.record(OperationReceipt(
                    id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                    revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal, outcome: .failedUnchanged,
                    sourceDisposition: .present, failure: String(describing: error)
                ), ownership: ownership)
            }
            throw error
        }
    }

    func recordUnstartedCommitFailure(_ identity: OperationRequestIdentity, ownership: OperationJournal.Ownership,
                                      failure: Error) async throws {
        let current = try journal.read(identity.id)
        guard let receipt = current.receipt, receipt.phase == .readyToCommit else { return }
        var recovery = receipt.recovery.filter { $0.purpose != .source }
        var detail = String(describing: failure)
        do {
            let commit = try await journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            guard let record = current.workspace, let destination = current.intent?.destination else {
                throw OperationContractError.invalidReceipt
            }
            let parent = try resolve(destination).directory
            try OperationWorkspace(parent: parent, record: record).removeScratch()
            recovery.removeAll { $0.purpose == .scratch }
        } catch { detail += "; scratch cleanup: \(error)" }
        try journal.record(OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: receipt.revision + 1, phase: .terminal, outcome: recovery.isEmpty ? .failedUnchanged : .partial,
            sourceDisposition: receipt.sourceDisposition, plannedPaths: receipt.plannedPaths,
            recovery: recovery, failure: detail
        ), ownership: ownership)
    }

}
