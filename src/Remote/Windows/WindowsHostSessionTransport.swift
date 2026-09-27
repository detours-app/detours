import Foundation
import RemoteOperationSupport

actor WindowsHostSessionTransport: RemoteHostSessionTransport {
    private let channel: PowerShellChannel
    private var generation: UInt64?
    private var retirement: Task<Void, Never>?
    private var provider: WindowsRemoteProvider?

    init(channel: PowerShellChannel) {
        self.channel = channel
    }

    func bind(provider: WindowsRemoteProvider) {
        self.provider = provider
    }

    func restoreWatches(generation: UInt64) async throws {
        guard self.generation == generation else { throw RemoteHostSessionError.obsoleteGeneration }
        try await provider?.reregisterWatchesAfterReconnect()
        guard self.generation == generation else { throw RemoteHostSessionError.obsoleteGeneration }
    }

    func handshake(generation: UInt64, onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        await retirement?.value
        try Task.checkCancellation()
        self.generation = generation
        await channel.startSessionGeneration(generation, onFailure: onFailure)
        try Task.checkCancellation()
        guard self.generation == generation else { throw RemoteHostSessionError.obsoleteGeneration }
        let script = try PowerShellScript(source: WindowsOperationScripts.protocolScript, arguments: WindowsOperationArguments(.handshake))
        let payload = try await channel.handshakeRequest(script, generation: generation)
        guard self.generation == generation else { throw RemoteHostSessionError.obsoleteGeneration }
        switch try OperationReply.decode(payload) {
        case .handshake(let reply): return reply
        case .incompatible(let reason): throw reason
        default: throw RemoteHostSessionError.invalidHandshake
        }
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
            await provider?.invalidateWatchWorkers()
            await channel.retireSessionGeneration(generation)
        }
        retirement = task
        await task.value
    }

    func setActivePaneCount(_ count: Int) async {
        await channel.setActivePaneCount(count)
    }
}
