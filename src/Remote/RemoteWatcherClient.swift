import Foundation

actor RemoteWatcherClient {
    private struct Registration {
        let watch: FileProviderWatch
        let remoteToken: UUID
        let onChange: @Sendable (Location) -> Void
    }

    private let hostID: UUID
    private let rpcClient: RemoteRPCClient
    private var registrationsByWatch: [FileProviderWatch: Registration] = [:]
    private var registrationsByRemoteToken: [UUID: Registration] = [:]
    private var eventTask: Task<Void, Never>?

    init(hostID: UUID, rpcClient: RemoteRPCClient) {
        self.hostID = hostID
        self.rpcClient = rpcClient
    }

    deinit {
        eventTask?.cancel()
    }

    func startConsuming(_ events: AsyncStream<RPCEnvelope>) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await envelope in events {
                await self?.receive(envelope)
            }
        }
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        guard case .remote(let locationHostID, let path) = location, locationHostID == hostID else {
            throw RemoteFileProviderError.expectedRemote(location)
        }

        let watch = FileProviderWatch(id: UUID(), location: location)
        let remoteToken = UUID()
        _ = try await rpcClient.send(.watch(path: RemotePath(path), token: remoteToken))

        let registration = Registration(watch: watch, remoteToken: remoteToken, onChange: onChange)
        registrationsByWatch[watch] = registration
        registrationsByRemoteToken[remoteToken] = registration
        return watch
    }

    func unwatch(_ watch: FileProviderWatch) async {
        guard let registration = registrationsByWatch.removeValue(forKey: watch) else { return }
        registrationsByRemoteToken.removeValue(forKey: registration.remoteToken)
        _ = try? await rpcClient.send(.unwatch(token: registration.remoteToken))
    }

    func receive(_ envelope: RPCEnvelope) {
        guard envelope.kind == .event,
              envelope.messageType == "WatchEvent",
              let message = try? RPCMessage(binaryEncoded: envelope.payload) else {
            return
        }
        receive(message)
    }

    func receive(_ message: RPCMessage) {
        guard case .watchEvent(let token, _, let path) = message,
              let registration = registrationsByRemoteToken[token] else {
            return
        }
        registration.onChange(.remote(hostID: hostID, path: path.lossyDisplayString))
    }
}
