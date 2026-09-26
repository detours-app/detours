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
        let kind: RemoteSessionLifetimeKind
        if case .operation = message { kind = .operation } else { kind = .reader }
        let lifetime = try await session.acquireLifetime(kind)
        defer { lifetime.release() }
        let ready = try await session.ensureReady()
        try Task.checkCancellation()
        try requireGeneration(ready.generation)
        if case .operation(let request) = message {
            return try await sendOperation(request, session: session)
        }
        let reply = try await client.send(message)
        try await session.requireGeneration(ready.generation)
        try Task.checkCancellation()
        return reply
    }

    private func sendOperation(_ request: OperationRequest, session: RemoteHostSession) async throws -> [Data] {
        let worker = try await connection.auxiliaryWorker()
        let progress = RemoteMeasuredProgress()
        let identity: OperationRequestIdentity?
        switch request {
        case .prepareUpload(let value, _), .prepareCopy(let value), .prepareArchive(let value, _), .execute(let value):
            identity = value
        default: identity = nil
        }
        let monitor = identity.map { identity in
            Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(5))
                        let chunks = try await self.sendOperation(.status(identity), session: session)
                        guard chunks.count == 1, let data = chunks.first,
                              case .status(let snapshot) = try OperationReply.decode(data),
                              snapshot.id == identity.id, snapshot.account == identity.account,
                              snapshot.epoch == identity.epoch, snapshot.intentDigest == identity.intentDigest else {
                            throw RemoteFileProviderError.invalidResponse("Unverified operation progress")
                        }
                        if let measured = snapshot.receipt?.measuredBytes { progress.record(measured) }
                    }
                } catch {
                    if !Task.isCancelled { progress.fail(error); worker.requestStop() }
                }
            }
        }
        defer { monitor?.cancel() }
        do {
            return try await session.performOwnedWorker(worker, kind: .operation) { worker in
                try Self.exchangeOperation(request, worker: worker, progress: identity == nil ? nil : progress)
            }
        } catch {
            try Task.checkCancellation()
            try progress.check()
            throw error
        }
    }

    static func exchangeOperation(_ request: OperationRequest, worker: RemoteProcessWorker,
                                  progress: RemoteMeasuredProgress?) throws -> [Data] {
        let message = RPCMessage.operation(request)
        let envelope = RPCEnvelope(id: 1, kind: .request, messageType: message.messageType,
            sequence: 0, isFinal: true, payload: try message.binaryEncoded())
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        try worker.start()
        try worker.write(RPCStreamHandler.encodeFrame(envelope.encodedPayload()),
                         timeout: progress == nil ? .seconds(10) : .seconds(30), progress: progress)
        worker.closeInput()
        var frames = RPCStreamHandler()
        var assembler = RPCResponseAssembler()
        while true {
            if let progress {
                try progress.check()
            } else if ContinuousClock.now >= deadline {
                throw RemoteProcessWorkerError.timedOut
            }
            let chunk: Data
            do {
                chunk = try worker.read(maximumBytes: 64 * 1024, timeout: .milliseconds(250))
            } catch RemoteProcessWorkerError.timedOut { continue }
            guard !chunk.isEmpty else { throw RemoteProcessWorkerError.closed }
            for frame in try frames.append(chunk) {
                let reply = try RPCEnvelope(encodedPayload: frame)
                guard reply.id == 1 else { continue }
                if reply.kind == .error { throw SSHRemoteRPCClient.decodeError(reply.payload) }
                guard reply.kind == .response else { throw RemoteFileProviderError.invalidResponse("Unexpected operation reply kind") }
                if let complete = assembler.receive(reply) {
                    guard try worker.waitForExit() == 0 else {
                        worker.finishDiagnostics()
                        throw RemoteTransferError.processFailed(worker.diagnostics)
                    }
                    return complete.chunks
                }
            }
        }
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
