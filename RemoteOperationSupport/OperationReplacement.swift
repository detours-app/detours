import Foundation

enum OperationReplacement {
    static func displace(journal: OperationJournal, snapshot: OperationJournal.Snapshot,
                         ownership: OperationJournal.Ownership) throws -> OperationReceipt {
        guard let intent = snapshot.intent, case .replace(let expected) = intent.conflict,
              let destination = intent.destination, let ready = snapshot.receipt,
              let record = snapshot.workspace else { throw OperationContractError.invalidReceipt }
        let target = try OperationPublication.split(destination)
        let parent = try OperationDirectory(path: target.parent)
        let current = try parent.observe(target.name)
        guard current.identity == expected.identity, current.version == expected.version else {
            throw OperationFilesystemError.identityChanged
        }
        let workspace = try OperationWorkspace(parent: parent, record: record)
        let name = Data("displaced".utf8)
        let holding = OperationLocation(account: journal.account, path: .unix(try workspace.directory.childPath(name)))
        guard case .missing = try workspace.directory.lookup(name) else { throw OperationFilesystemError.unexpectedContents }
        let reference = OperationRecoveryReference(
            identity: expected.identity, purpose: .displacedOriginal, original: destination,
            knownLocation: nil, possibleLocations: [destination, holding]
        )
        let planned = replacing(ready, recovery: ready.recovery + [reference], phase: .committing)
        try journal.record(planned, ownership: ownership)
        do {
            _ = try parent.moveExclusive(target.name, to: workspace.directory, named: name, expected: expected)
        } catch {
            try restore(journal: journal, id: snapshot.id, ownership: ownership, failure: String(describing: error))
            throw error
        }
        let confirmed = OperationRecoveryReference(
            identity: expected.identity, purpose: .displacedOriginal, original: destination,
            knownLocation: holding, possibleLocations: [holding]
        )
        let displaced = replacing(planned, recovery: ready.recovery + [confirmed], phase: .committing)
        try journal.record(displaced, ownership: ownership)
        return displaced
    }

    static func restore(journal: OperationJournal, id: OperationItemID, ownership: OperationJournal.Ownership,
                        failure: String) throws {
        let snapshot = try journal.read(id)
        guard let receipt = snapshot.receipt, let reference = receipt.recovery.first(where: { $0.purpose == .displacedOriginal }),
              let original = reference.original,
              let holding = reference.possibleLocations.first(where: { $0 != original }) else {
            throw OperationContractError.invalidReceipt
        }
        let source = try OperationPublication.split(holding)
        let target = try OperationPublication.split(original)
        let targetDirectory = try OperationDirectory(path: target.parent)
        guard let record = snapshot.workspace else { throw OperationContractError.invalidReceipt }
        let workspace = try OperationWorkspace(parent: targetDirectory, record: record)
        guard workspace.directory.path == source.parent else { throw OperationContractError.invalidReceipt }
        let sourceDirectory = workspace.directory
        let rollback = replacing(receipt, recovery: receipt.recovery, phase: .rollingBack)
        try journal.record(rollback, ownership: ownership)
        var recovery = rollback.recovery
        var detail = failure
        do {
            switch try sourceDirectory.lookup(source.name) {
            case .found(let actual):
                let retained = OperationRecoveryReference(
                    identity: actual.identity, purpose: .displacedOriginal, original: original,
                    knownLocation: holding, possibleLocations: [holding]
                )
                recovery.removeAll { $0.purpose == .displacedOriginal }
                recovery.append(retained)
                let located = replacing(rollback, recovery: recovery, phase: .rollingBack)
                try journal.record(located, ownership: ownership)
                _ = try sourceDirectory.moveExclusive(source.name, to: targetDirectory, named: target.name, expected: actual)
                recovery.removeAll { $0.purpose == .displacedOriginal }
            case .missing:
                if case .found(let actual) = try targetDirectory.lookup(target.name), actual.identity == reference.identity {
                    recovery.removeAll { $0.purpose == .displacedOriginal }
                }
            case .denied, .unsupported, .disconnected:
                throw OperationFilesystemError.unsupported
            }
        } catch {
            detail += "; restoration: \(error)"
            recovery = recovery.map { item in
                guard item.purpose == .displacedOriginal else { return item }
                var known: OperationLocation?
                do {
                    if case .found(let held) = try sourceDirectory.lookup(source.name), held.identity == item.identity {
                        known = holding
                    } else if case .found(let restored) = try targetDirectory.lookup(target.name), restored.identity == item.identity {
                        known = original
                    }
                } catch { detail += "; location check: \(error)" }
                return OperationRecoveryReference(identity: item.identity, purpose: item.purpose, original: original,
                                                  knownLocation: known, possibleLocations: [holding, original])
            }
        }
        let current = try journal.read(id)
        guard let latest = current.receipt else { throw OperationContractError.invalidReceipt }
        let result = replacing(latest, recovery: recovery, phase: .terminal, outcome: .partial, failure: detail)
        try journal.record(result, ownership: ownership)
    }

    private static func replacing(_ receipt: OperationReceipt, recovery: [OperationRecoveryReference], phase: OperationPhase,
                                  outcome: OperationOutcome = .running, failure: String? = nil) -> OperationReceipt {
        OperationReceipt(
            id: receipt.id, account: receipt.account, epoch: receipt.epoch, intentDigest: receipt.intentDigest,
            revision: receipt.revision + 1, phase: phase, outcome: outcome, effects: receipt.effects,
            sourceDisposition: receipt.sourceDisposition, contentVerified: receipt.contentVerified,
            preparedPayload: receipt.preparedPayload, plannedPaths: receipt.plannedPaths,
            measuredBytes: receipt.measuredBytes, recovery: recovery, children: receipt.children, failure: failure
        )
    }
}
