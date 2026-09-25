import Foundation
import RemoteOperationSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
}
