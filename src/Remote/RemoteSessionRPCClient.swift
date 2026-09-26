import Foundation
import RemoteOperationSupport

actor RemoteSessionRPCClient: RemoteRPCClient, RemoteHostSessionTransport {
    private let connection: SSHConnection
    private let client: SSHRemoteRPCClient
    private weak var session: RemoteHostSession?
    private weak var watcher: RemoteWatcherClient?
    private var generation: UInt64?
    private var retirement: Task<Void, Never>?

    init(connection: SSHConnection, client: SSHRemoteRPCClient) {
        self.connection = connection
        self.client = client
    }

    func bind(session: RemoteHostSession, watcher: RemoteWatcherClient) {
        self.session = session
        self.watcher = watcher
    }

    func send(_ message: RPCMessage) async throws -> [Data] {
        guard let session else { throw RemoteHostSessionError.retired }
        let lifetime = try await session.acquireLifetime(.reader)
        defer { lifetime.release() }
        let ready = try await session.ensureReady()
        try Task.checkCancellation()
        try requireGeneration(ready.generation)
        let reply = try await client.send(message)
        try await session.requireGeneration(ready.generation)
        try Task.checkCancellation()
        return reply
    }

    func handshake(generation: UInt64, onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        await retirement?.value
        try Task.checkCancellation()
        self.generation = generation
        await connection.manageBySession { reason in await onFailure(generation, reason) }
        try requireGeneration(generation)
        await client.setFailureHandler { error in await onFailure(generation, RemoteHostSession.reason(for: error)) }
        try requireGeneration(generation)
        try await connection.connect()
        try requireGeneration(generation)
        let chunks = try await client.send(.operation(.handshake))
        try requireGeneration(generation)
        guard chunks.count == 1, let payload = chunks.first else { throw RemoteHostSessionError.invalidHandshake }
        switch try OperationReply.decode(payload) {
        case .handshake(let reply): return reply
        case .incompatible(let reason): throw reason
        default: throw RemoteHostSessionError.invalidHandshake
        }
    }

    func restoreWatches(generation: UInt64) async throws {
        try requireGeneration(generation)
        try await watcher?.reregisterWatchesAfterReconnect(using: client)
        try requireGeneration(generation)
    }

    func retire(generation: UInt64) async {
        guard self.generation == generation else {
            await retirement?.value
            return
        }
        self.generation = nil
        let previous = retirement
        let task = Task {
            await previous?.value
            await watcher?.invalidateRemoteTokens()
            await client.prepareForReconnect()
            await connection.disconnect()
        }
        retirement = task
        await task.value
    }

    func setActivePaneCount(_ count: Int) async {
        await connection.setActivePaneCount(count)
    }

    private func requireGeneration(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw RemoteHostSessionError.obsoleteGeneration }
    }
}
