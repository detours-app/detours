import Foundation

enum ServerRPCError: Error, Equatable {
    case unsupportedCommand(String)
}

struct RPCHandler {
    private let fileOperations = FileOperations()

    func run() throws {
        var stream = ServerRPCStreamHandler()

        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 4096)
            guard !chunk.isEmpty else { return }

            for frame in try stream.append(chunk) {
                let request = try ServerRPCEnvelope(encodedPayload: frame)
                guard request.kind == .request else { continue }

                let payload = try handle(message: ServerRPCMessage(binaryEncoded: request.payload))
                let response = ServerRPCEnvelope(
                    id: request.id,
                    kind: .response,
                    messageType: request.messageType,
                    sequence: 0,
                    isFinal: true,
                    payload: payload
                )
                FileHandle.standardOutput.write(try ServerRPCStreamHandler.encodeFrame(response.encodedPayload()))
            }
        }
    }

    func handle(command: String) throws -> String {
        switch command {
        case "ProtocolVersion":
            return "1"
        default:
            throw ServerRPCError.unsupportedCommand(command)
        }
    }

    func handle(message: ServerRPCMessage) throws -> Data {
        switch message {
        case .protocolVersion:
            var writer = ServerRPCBinaryWriter()
            writer.writeInt64(1)
            return writer.data
        case .list(let path, let showHidden):
            return try fileOperations.list(path: path, showHidden: showHidden)
        case .stat(let path):
            return try fileOperations.stat(path: path)
        case .download(let path, let maximumRPCBytes):
            return try fileOperations.download(path: path, maximumRPCBytes: maximumRPCBytes)
        case .upload(let path, let contents, let expectedByteCount, let maximumRPCBytes):
            try fileOperations.upload(
                path: path,
                contents: contents,
                expectedByteCount: expectedByteCount,
                maximumRPCBytes: maximumRPCBytes
            )
            return Data()
        case .fileVersion(let path):
            return try fileOperations.fileVersion(path: path)
        case .readSymlink(let path):
            return try fileOperations.readSymlink(path: path)
        case .folderSize(let path):
            return try fileOperations.folderSize(path: path)
        case .gitStatus(let directory):
            return try fileOperations.gitStatus(directory: directory)
        }
    }
}
