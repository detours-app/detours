import Foundation

enum ServerRPCError: Error, Equatable {
    case unsupportedCommand(String)
}

struct RPCHandler {
    private let fileOperations = FileOperations()
    private let watcher = Watcher()

    func run() throws {
        var stream = ServerRPCStreamHandler()

        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 4096)
            guard !chunk.isEmpty else { return }

            for frame in try stream.append(chunk) {
                let request = try ServerRPCEnvelope(encodedPayload: frame)
                guard request.kind == .request else { continue }

                let payloads = try handleChunks(message: ServerRPCMessage(binaryEncoded: request.payload))
                for (index, payload) in payloads.enumerated() {
                    let response = ServerRPCEnvelope(
                        id: request.id,
                        kind: .response,
                        messageType: request.messageType,
                        sequence: UInt32(index),
                        isFinal: index == payloads.count - 1,
                        payload: payload
                    )
                    FileHandle.standardOutput.write(try ServerRPCStreamHandler.encodeFrame(response.encodedPayload()))
                }
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
        guard let payload = try handleChunks(message: message).first else { return Data() }
        return payload
    }

    func handleChunks(message: ServerRPCMessage) throws -> [Data] {
        switch message {
        case .protocolVersion:
            var writer = ServerRPCBinaryWriter()
            writer.writeInt64(1)
            return [writer.data]
        case .list(let path, let showHidden):
            return try fileOperations.listChunks(path: path, showHidden: showHidden)
        case .stat(let path):
            return [try fileOperations.stat(path: path)]
        case .copy(let sources, let destination, let maximumRPCBytes):
            return [try fileOperations.copy(sources: sources, destination: destination, maximumRPCBytes: maximumRPCBytes)]
        case .move(let sources, let destination):
            return [try fileOperations.move(sources: sources, destination: destination)]
        case .rename(let item, let newName):
            return [try fileOperations.rename(item: item, newName: newName)]
        case .delete(let items):
            _ = try fileOperations.trash(items: items)
            return [Data()]
        case .trash(let items):
            return [try fileOperations.trash(items: items)]
        case .restoreFromTrash(let items):
            return [try fileOperations.restoreFromTrash(items: items)]
        case .mkDir(let path):
            return [try fileOperations.mkDir(path: path)]
        case .archiveCreate(let items, let format, let archiveName, let password):
            return [try fileOperations.archiveCreate(
                items: items,
                format: format,
                archiveName: archiveName,
                password: password
            )]
        case .archiveExtract(let archive, let password):
            return [try fileOperations.archiveExtract(archive: archive, password: password)]
        case .download(let path, let maximumRPCBytes):
            return [try fileOperations.download(path: path, maximumRPCBytes: maximumRPCBytes)]
        case .upload(let path, let contents, let expectedByteCount, let maximumRPCBytes):
            try fileOperations.upload(
                path: path,
                contents: contents,
                expectedByteCount: expectedByteCount,
                maximumRPCBytes: maximumRPCBytes
            )
            return [Data()]
        case .fileVersion(let path):
            return [try fileOperations.fileVersion(path: path)]
        case .readSymlink(let path):
            return [try fileOperations.readSymlink(path: path)]
        case .folderSize(let path):
            return [try fileOperations.folderSize(path: path)]
        case .gitStatus(let directory):
            return [try fileOperations.gitStatus(directory: directory)]
        case .watch(let path, let token):
            try watcher.watchVisibleDirectory(path.string, token: token)
            return [Data()]
        case .unwatch(let token):
            try watcher.unwatch(token)
            return [Data()]
        }
    }
}
