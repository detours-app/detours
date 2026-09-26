import Foundation

enum RemoteSessionLifetimeKind: Sendable {
    case pane, watch, reader, operation
}

final class RemoteSessionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: RemoteHostSession?
    private let id: UUID

    init(owner: RemoteHostSession, id: UUID) {
        self.owner = owner
        self.id = id
    }

    func release() {
        guard let owner = takeOwner() else { return }
        let id = id
        Task { await owner.releaseLifetime(id) }
    }

    func releaseAndWait() async {
        guard let owner = takeOwner() else { return }
        await owner.releaseLifetime(id)
    }

    private func takeOwner() -> RemoteHostSession? {
        lock.withLock {
            let result = owner
            owner = nil
            return result
        }
    }

    deinit { release() }
}
