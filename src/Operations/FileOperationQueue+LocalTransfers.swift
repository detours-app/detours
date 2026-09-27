import Darwin
import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    nonisolated static let localTransferHostID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    static func operationHostID(_ location: Location) -> UUID {
        if case .remote(let hostID, _) = location { return hostID }
        return localTransferHostID
    }

    func registerLocalTransferService(_ service: LocalTransferService) {
        registerRemoteFileProvider(LocalFileProvider.shared, for: Self.localTransferHostID, operationEndpoint: service.endpoint())
    }

    func ensureLocalTransferService() async throws {
        guard remoteOperationEndpoints[Self.localTransferHostID] == nil else { return }
        var machine: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var deadline = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&machine, &deadline) == 0 else { throw OperationFilesystemError.system(errno) }
        let account = OperationAccount(hostIdentity: UUID(uuid: machine).uuidString, accountIdentity: String(getuid()))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("Detours/RemoteOperations/LocalJournal", isDirectory: true)
        let journal = try await OperationJournal(root: root, account: account)
        registerLocalTransferService(.init(journal: journal))
    }
}
