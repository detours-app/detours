import Foundation
import RemoteOperationSupport

/// UI-test seam: runs the app's bundled helper as a local process, so the fake remote's renames
/// and moves go through the same recorded operations a real remote host performs.
actor UITestLocalHelper {
    enum HelperError: Error, LocalizedError {
        case missingHelper(String)
        case invalidReply

        var errorDescription: String? {
            switch self {
            case .missingHelper(let path): return "The bundled helper is missing at \(path)."
            case .invalidReply: return "The local helper returned an invalid reply."
            }
        }
    }

    private let worker: RemoteProcessWorker
    private var nextRequestID: UInt64 = 1
    private var lastExchange: Task<OperationReply, Error>?

    /// Starts the bundled Darwin helper, keeping its operation journal and trash under `operationHome`.
    init(operationHome: URL) throws {
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("Servers/detours-server-x86_64-darwin"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw HelperError.missingHelper(Bundle.main.bundlePath + "/Contents/Resources/Servers")
        }
        try FileManager.default.createDirectory(at: operationHome, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--operation-home", operationHome.path]
        worker = RemoteProcessWorker(process: process)
        try worker.start()
    }

    /// One exchange at a time: replies are read in order from the helper's single output stream.
    func operationRequest(_ request: OperationRequest) async throws -> OperationReply {
        let id = nextRequestID
        nextRequestID += 1
        let previous = lastExchange
        let worker = self.worker
        let exchange = Task {
            _ = await previous?.result
            return try await Self.exchange(request, id: id, worker: worker)
        }
        lastExchange = exchange
        return try await exchange.value
    }

    func prepareUpload(_ localURL: URL, identity: OperationRequestIdentity) async throws -> OperationReceipt {
        let contents = try Data(contentsOf: localURL)
        guard case .receipt(let receipt) = try await operationRequest(.prepareUpload(identity: identity, contents: contents)) else {
            throw OperationContractError.invalidReceipt
        }
        return receipt
    }

    nonisolated func endpoint() -> RemoteOperationCoordinator.Endpoint {
        let session = RemoteHostSession(transport: UITestLocalHelperTransport(helper: self), publish: { _, _ in })
        return .init(session: session,
                     request: { try await self.operationRequest($0) },
                     upload: { try await self.prepareUpload($0, identity: $1) })
    }

    private static func exchange(_ request: OperationRequest, id: UInt64, worker: RemoteProcessWorker) async throws -> OperationReply {
        let message = RPCMessage.operation(request)
        let envelope = RPCEnvelope(id: id, kind: .request, messageType: message.messageType,
                                   sequence: 0, isFinal: true, payload: try message.binaryEncoded())
        let frame = try RPCStreamHandler.encodeFrame(envelope.encodedPayload())
        try await worker.perform { try $0.write(frame) }
        var assembler = RPCResponseAssembler()
        while true {
            let payload = try await worker.perform { try $0.readFrame(timeout: .seconds(30)) }
            let reply = try RPCEnvelope(encodedPayload: payload)
            guard reply.id == id else { continue }
            if reply.kind == .error { throw SSHRemoteRPCClient.decodeError(reply.payload) }
            if let assembled = assembler.receive(reply) {
                guard assembled.chunks.count == 1, let chunk = assembled.chunks.first else { throw HelperError.invalidReply }
                return try OperationReply.decode(chunk)
            }
        }
    }
}

private struct UITestLocalHelperTransport: RemoteHostSessionTransport {
    let helper: UITestLocalHelper

    func handshake(generation: UInt64,
                   onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        guard case .handshake(let handshake) = try await helper.operationRequest(.handshake) else {
            throw RemoteHostSessionError.invalidHandshake
        }
        return handshake
    }

    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}
