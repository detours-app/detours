import Foundation
import RemoteOperationSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ServerPayloadPreparation: @unchecked Sendable {
    let workspace: OperationWorkspace
    let location: OperationLocation
    let payload: OperationLocation
}

extension ServerOperationService {
    func requirePreparationDestination(_ intent: OperationIntent) throws {
        guard let destination = intent.destination else { throw OperationContractError.invalidReceipt }
        let target = try resolve(destination)
        switch try target.directory.lookup(target.name) {
        case .missing:
            guard intent.conflict == .createNew else { throw OperationFilesystemError.identityChanged }
        case .found(let current):
            guard case .replace(let expected) = intent.conflict else { throw OperationFilesystemError.system(EEXIST) }
            guard current.identity == expected.identity, current.kind == expected.kind,
                  current.version == expected.version, current.linkTarget == expected.linkTarget else {
                throw OperationFilesystemError.identityChanged
            }
        case .denied: throw OperationFilesystemError.system(EACCES)
        case .disconnected: throw OperationFilesystemError.system(ENOTCONN)
        case .unsupported: throw OperationFilesystemError.unsupported
        }
    }

    func recordUnallocatedFailure(_ id: OperationItemID, ownership: OperationJournal.Ownership, failure: Error) throws {
        let current = try journal.read(id)
        guard current.workspace == nil, current.receipt?.plannedPaths == nil,
              current.receipt?.phase != .terminal else { return }
        try journal.record(OperationReceipt(
            id: id, account: journal.account, epoch: journal.epoch, intentDigest: current.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal, outcome: .failedUnchanged,
            sourceDisposition: current.intent?.action == .move ? .present : .notRequired,
            failure: String(describing: failure)
        ), ownership: ownership)
    }

    func allocatePreparation(_ identity: OperationRequestIdentity, target: OperationDirectory,
                             ownership: OperationJournal.Ownership) async throws -> ServerPayloadPreparation {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
        guard let intent = try journal.read(identity.id).intent else { throw OperationContractError.invalidReceipt }
        try requirePreparationDestination(intent)
        let name = OperationWorkspace.plannedName(for: identity.id)
        let location = OperationLocation(account: journal.account, path: .unix(try target.childPath(name)))
        let current = try journal.read(identity.id)
        try journal.record(OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: .preparing, outcome: .running,
            sourceDisposition: current.intent?.action == .move ? .present : .notRequired, plannedPaths: [location]
        ), ownership: ownership)
        let workspace = try OperationWorkspace(parent: target, id: identity.id, plannedName: name)
        try journal.recordWorkspace(workspace.record, ownership: ownership)
        let payload = OperationLocation(account: journal.account, path: .unix(try workspace.directory.childPath(Data("payload".utf8))))
        return ServerPayloadPreparation(workspace: workspace, location: location, payload: payload)
    }

    func failPreparation(_ identity: OperationRequestIdentity, preparation: ServerPayloadPreparation?,
                         ownership: OperationJournal.Ownership, failure: Error) async throws {
        var recovery: [OperationRecoveryReference] = []
        var detail = String(describing: failure)
        let current = try journal.read(identity.id)
        var outcome: OperationOutcome = current.receipt?.plannedPaths == nil ? .failedUnchanged : .unknown
        if let preparation {
            do {
                let commit = try await journal.acquireCommit()
                defer { withExtendedLifetime(commit) {} }
                try preparation.workspace.removeScratch()
                outcome = .failedUnchanged
            } catch {
                outcome = .partial
                detail += "; scratch cleanup: \(error)"
                var known: OperationLocation?
                do {
                    let root = try resolve(preparation.location)
                    if case .found(let observed) = try root.directory.lookup(root.name),
                       observed.identity == preparation.workspace.record.root.identity { known = preparation.location }
                } catch { detail += "; location check: \(error)" }
                recovery = [.init(identity: preparation.workspace.record.root.identity, purpose: .scratch, original: nil,
                                  knownLocation: known, possibleLocations: [preparation.location])]
            }
        }
        try journal.record(OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal, outcome: outcome,
            sourceDisposition: current.intent?.action == .move ? .present : .notRequired,
            plannedPaths: current.receipt?.plannedPaths, recovery: recovery, failure: detail
        ), ownership: ownership)
    }
}
