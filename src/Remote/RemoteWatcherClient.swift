import Foundation

actor RemoteWatcherClient {
    private struct Registration {
        let watch: FileProviderWatch
        let remoteToken: UUID
        let onChange: @Sendable (Location) -> Void
    }

    private let hostID: UUID
    private let rpcClient: RemoteRPCClient
    private let pollFallback: RemoteWatcherPollFallback?
    private let pollSnapshotLoader: (@Sendable (Location) async throws -> [LoadedFileEntry])?
    private let inotifyLimitCommand: @Sendable (Error) -> String?
    private var registrationsByWatch: [FileProviderWatch: Registration] = [:]
    private var registrationsByRemoteToken: [UUID: Registration] = [:]
    private var eventTask: Task<Void, Never>?

    init(
        hostID: UUID,
        rpcClient: RemoteRPCClient,
        pollFallback: RemoteWatcherPollFallback? = nil,
        pollSnapshotLoader: (@Sendable (Location) async throws -> [LoadedFileEntry])? = nil,
        inotifyLimitCommand: @escaping @Sendable (Error) -> String? = { _ in nil }
    ) {
        self.hostID = hostID
        self.rpcClient = rpcClient
        self.pollFallback = pollFallback
        self.pollSnapshotLoader = pollSnapshotLoader
        self.inotifyLimitCommand = inotifyLimitCommand
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

        let remoteToken = UUID()
        let watch = FileProviderWatch(id: UUID(), location: location)

        do {
            _ = try await rpcClient.send(.watch(path: RemotePath(path), token: remoteToken))
        } catch {
            if let command = inotifyLimitCommand(error),
               let pollFallback,
               let pollSnapshotLoader {
                await pollFallback.start(
                    watch: watch,
                    inotifyLimitCommand: command,
                    loadSnapshot: { try await pollSnapshotLoader(location) },
                    onChange: onChange
                )
                return watch
            }
            throw error
        }

        let registration = Registration(watch: watch, remoteToken: remoteToken, onChange: onChange)
        registrationsByWatch[watch] = registration
        registrationsByRemoteToken[remoteToken] = registration
        return watch
    }

    func unwatch(_ watch: FileProviderWatch) async {
        guard let registration = registrationsByWatch.removeValue(forKey: watch) else {
            await pollFallback?.stop(watch)
            return
        }
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
