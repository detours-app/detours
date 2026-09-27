import Foundation
import RemoteOperationSupport

extension LocalTransferService {
    func commit(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        _ = try read(identity)
        let ownership = try await journal.acquireItem(identity.id)
        let snapshot = try read(identity)
        if let receipt = snapshot.receipt, [.terminal, .committed].contains(receipt.phase) { return receipt }
        do {
            _ = try await OperationPublication.publish(journal: journal, id: identity.id, ownership: ownership)
        } catch {
            let current = try read(identity)
            if let receipt = current.receipt, receipt.phase == .terminal { return receipt }
            if current.receipt?.phase == .readyToCommit {
                var failure = String(describing: error)
                var recovery = current.receipt?.recovery ?? []
                do {
                    guard let record = current.workspace, let destination = current.intent?.destination else {
                        throw OperationContractError.invalidReceipt
                    }
                    let parent = try OperationDirectory(path: LocalTransferPublication.split(destination).parent)
                    try OperationWorkspace(parent: parent, record: record).removeScratch()
                    recovery = []
                } catch { failure += "; scratch cleanup: \(error)" }
                let stopped = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
                    intentDigest: identity.intentDigest, revision: (current.receipt?.revision ?? 0) + 1,
                    phase: .terminal, outcome: recovery.isEmpty ? .failedUnchanged : .partial, recovery: recovery, failure: failure)
                try journal.record(stopped, ownership: ownership)
                return stopped
            }
            if current.receipt?.outcome == .committed { return try requireReceipt(current) }
            return try record(identity, phase: .terminal, outcome: .unknown, ownership: ownership,
                              failure: String(describing: error))
        }
        var receipt = try requireReceipt(read(identity))
        for reference in receipt.recovery where reference.purpose == .displacedOriginal {
            receipt = try handoffToTrash(reference, identity: identity, ownership: ownership)
        }
        guard let workspaceRecord = snapshot.workspace, let destination = snapshot.intent?.destination else { return receipt }
        let parent = try OperationDirectory(path: LocalTransferPublication.split(destination).parent)
        let workspace = try OperationWorkspace(parent: parent, record: workspaceRecord)
        let root = try parent.childPath(workspaceRecord.root.name)
        let retainsOriginal = receipt.recovery.contains { reference in
            guard reference.purpose == .displacedOriginal else { return false }
            guard let location = reference.knownLocation, case .unix(let path) = location.path else { return true }
            return path.starts(with: root + Data([47]))
        }
        if retainsOriginal { return try record(identity, phase: .terminal, outcome: .committed, ownership: ownership, failure: receipt.failure) }
        do {
            try workspace.removeScratch()
            return try record(identity, phase: .terminal, outcome: .committed, ownership: ownership,
                recovery: receipt.recovery.filter { $0.purpose != .scratch }, failure: receipt.failure)
        } catch {
            return try record(identity, phase: .terminal, outcome: .committed, ownership: ownership,
                failure: [receipt.failure, "Scratch cleanup: \(error)"].compactMap { $0 }.joined(separator: "; "))
        }
    }

    func handoffToTrash(_ reference: OperationRecoveryReference, identity: OperationRequestIdentity,
                        ownership: OperationJournal.Ownership) throws -> OperationReceipt {
        guard let location = reference.knownLocation, case .unix(let bytes) = location.path,
              let path = String(data: bytes, encoding: .utf8) else { throw OperationContractError.invalidReceipt }
        let target = try LocalTransferPublication.split(location)
        let directory = try OperationDirectory(path: target.parent)
        let before = try directory.manifest(target.name, progress: { _ in })
        guard before.entries.first?.observation.identity == reference.identity else { throw OperationFilesystemError.identityChanged }
        let phase: OperationPhase = reference.purpose == .sourceTrash ? .committing : .committed
        let outcome: OperationOutcome = reference.purpose == .sourceTrash ? .running : .committed
        let original = URL(fileURLWithPath: path)
        var current = try requireReceipt(read(identity))
        do {
            let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: original, create: true)
            guard try OperationDirectory(path: Data(trash.path.utf8)).identity.volume == reference.identity.volume else {
                throw OperationFilesystemError.unsupported
            }
            let unknown = OperationRecoveryReference(identity: reference.identity, purpose: reference.purpose,
                original: reference.original, knownLocation: nil, possibleLocations: [location])
            current = try record(identity, phase: phase, outcome: outcome, ownership: ownership,
                recovery: current.recovery.filter { $0 != reference } + [unknown])
            var returned: NSURL?
            try FileManager.default.trashItem(at: original, resultingItemURL: &returned)
            guard let result = returned as URL? else { throw OperationContractError.invalidReceipt }
            let known = OperationLocation(account: journal.account, path: .unix(Data(result.path.utf8)))
            let returnedReference = OperationRecoveryReference(identity: reference.identity, purpose: reference.purpose,
                original: reference.original, knownLocation: nil, possibleLocations: [location, known])
            current = try record(identity, phase: phase, outcome: outcome, ownership: ownership,
                recovery: current.recovery.filter { $0.identity != reference.identity } + [returnedReference])
            let parent = try OperationDirectory(path: Data(result.deletingLastPathComponent().path.utf8))
            let after = try parent.manifest(Data(result.lastPathComponent.utf8), progress: { _ in })
            guard before.matchesMovedObjects(after) else { throw OperationFilesystemError.identityChanged }
            let retained = OperationRecoveryReference(identity: reference.identity, purpose: reference.purpose,
                original: reference.original, knownLocation: known, possibleLocations: [known])
            let effects: [OperationEffect]?
            if reference.purpose == .sourceTrash {
                guard let root = after.entries.first?.observation else { throw OperationContractError.invalidReceipt }
                let proof = OperationObservation(identity: root.identity, kind: root.kind, version: root.version,
                    byteCount: root.byteCount, sha256: root.kind == .file ? root.sha256 : after.proof.sha256,
                    linkTarget: root.linkTarget, contentVersion: root.contentVersion)
                effects = [.init(location: known, observation: proof)]
            } else { effects = nil }
            return try record(identity, phase: phase, outcome: outcome, ownership: ownership,
                              recovery: current.recovery.filter { $0.identity != reference.identity } + [retained], effects: effects)
        } catch {
            var recovery = current.recovery
            if case .found(let remaining) = try directory.lookup(target.name), remaining.identity == reference.identity {
                recovery = recovery.filter { $0.identity != reference.identity } + [reference]
            }
            return try record(identity, phase: phase, outcome: outcome, ownership: ownership,
                recovery: recovery, failure: "The original's Trash handoff could not be confirmed: \(error)")
        }
    }

    private func requireReceipt(_ snapshot: OperationJournal.Snapshot) throws -> OperationReceipt {
        guard let receipt = snapshot.receipt else { throw OperationContractError.invalidReceipt }
        return receipt
    }
}
