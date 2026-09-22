import DetoursProcess
import Foundation

enum ServerRPCError: Error, Equatable {
    case unsupportedCommand(String)
}

/// Safe to serve from several queues at once: the file operations hold no
/// mutable state, and the watcher guards its registries with its own lock.
struct RPCHandler: @unchecked Sendable {
    private let fileOperations = FileOperations()
    private let watcher = Watcher()

    func run() throws {
        let outputLock = NSLock()
        let eventPump = EventPump()
        let watcher = self.watcher
        DispatchQueue.global(qos: .utility).async {
            while eventPump.isRunning {
                do {
                    for event in try watcher.pendingEvents() {
                        let envelope = ServerRPCEnvelope(
                            id: 0,
                            kind: .event,
                            messageType: "WatchEvent",
                            sequence: 0,
                            isFinal: true,
                            payload: Self.encodeWatchEvent(event)
                        )
                        try Self.write(envelope: envelope, outputLock: outputLock)
                    }
                } catch {
                    // Watch delivery is best-effort; RPC watch setup reports typed setup failures.
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        defer { eventPump.stop() }

        // Serving one request at a time made every client stall behind the
        // slowest one: a folder size, an archive, or a git status in a large
        // repository held up listings the user was waiting to see. Reads now run
        // in parallel, while anything that changes the filesystem runs as a
        // barrier so it still observes, and is observed by, the requests around
        // it in the order the client sent them.
        let workQueue = DispatchQueue(label: "com.detours.server.rpc", attributes: .concurrent)
        defer { workQueue.sync(flags: .barrier) {} }

        while true {
            guard let frame = try Self.readFrame(from: .standardInput) else { return }
            let request = try ServerRPCEnvelope(encodedPayload: frame)
            guard request.kind == .request else { continue }

            let message: ServerRPCMessage
            do {
                message = try ServerRPCMessage(binaryEncoded: request.payload)
            } catch {
                try Self.writeError(error, for: request, outputLock: outputLock)
                continue
            }

            let work: @Sendable () -> Void = {
                self.serve(message: message, request: request, outputLock: outputLock)
            }
            if Self.mutatesRemoteState(message) {
                workQueue.async(flags: .barrier, execute: work)
            } else {
                workQueue.async(execute: work)
            }
        }
    }

    /// Whether a message changes remote state, and so must not overlap with the
    /// requests before or after it.
    private static func mutatesRemoteState(_ message: ServerRPCMessage) -> Bool {
        switch message {
        case .protocolVersion, .list, .stat, .readSymlink, .folderSize, .gitStatus, .fileVersion, .download, .find:
            return false
        case .copy, .move, .rename, .delete, .trash, .restoreFromTrash, .mkDir, .symlink,
             .archiveCreate, .archiveExtract, .upload, .watch, .unwatch:
            return true
        }
    }

    private func serve(message: ServerRPCMessage, request: ServerRPCEnvelope, outputLock: NSLock) {
        do {
            if case .find(let query, let cap) = message {
                // Find streams results as they are discovered so the client can render
                // progressively; each batch is its own response envelope.
                try Self.streamFind(query: query, cap: cap, request: request, outputLock: outputLock)
                return
            }
            let payloads = try handleChunks(message: message)
            for (index, payload) in payloads.enumerated() {
                let response = ServerRPCEnvelope(
                    id: request.id,
                    kind: .response,
                    messageType: request.messageType,
                    sequence: UInt32(index),
                    isFinal: index == payloads.count - 1,
                    payload: payload
                )
                try Self.write(envelope: response, outputLock: outputLock)
            }
        } catch {
            // A single request failing must not bring down the daemon: report it to the client
            // as a per-request error envelope and keep serving the connection.
            try? Self.writeError(error, for: request, outputLock: outputLock)
        }
    }

    private static func writeError(_ error: Error, for request: ServerRPCEnvelope, outputLock: NSLock) throws {
        let response = ServerRPCEnvelope(
            id: request.id,
            kind: .error,
            messageType: request.messageType,
            sequence: 0,
            isFinal: true,
            payload: Self.encodeError(error)
        )
        try Self.write(envelope: response, outputLock: outputLock)
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
            try fileOperations.delete(items: items)
            return [Data()]
        case .trash(let items):
            return [try fileOperations.trash(items: items)]
        case .restoreFromTrash(let items):
            return [try fileOperations.restoreFromTrash(items: items)]
        case .mkDir(let path):
            return [try fileOperations.mkDir(path: path)]
        case .symlink(let path, let targetPath):
            return [try fileOperations.symlink(path: path, targetPath: targetPath)]
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
        case .find(let query, let cap):
            // Non-streaming fallback (the run loop normally streams find via streamFind).
            let finder = FindOperations(resultCap: Int(cap))
            var chunks: [Data] = []
            finder.find(query: query) { chunks.append(FindOperations.encode($0)) }
            return chunks.isEmpty ? [FindOperations.encode([])] : chunks
        case .watch(let path, let token):
            try watcher.watchVisibleDirectory(path.string, token: token)
            return [Data()]
        case .unwatch(let token):
            do {
                try watcher.unwatch(token)
            } catch ServerWatcherError.unknownWatch {
                // Releasing an already-unwatched token (e.g. after a reconnect) is a no-op, not an error.
            }
            return [Data()]
        }
    }

    private static func streamFind(query: Data, cap: Int64, request: ServerRPCEnvelope, outputLock: NSLock) throws {
        let finder = FindOperations(resultCap: Int(cap))
        var sequence: UInt32 = 0
        finder.find(query: query) { batch in
            let envelope = ServerRPCEnvelope(
                id: request.id,
                kind: .response,
                messageType: request.messageType,
                sequence: sequence,
                isFinal: false,
                payload: FindOperations.encode(batch)
            )
            try? Self.write(envelope: envelope, outputLock: outputLock)
            sequence += 1
        }
        // Always send a terminating empty chunk so the client knows the search finished
        // (and can distinguish "still searching" from "no matches").
        let final = ServerRPCEnvelope(
            id: request.id,
            kind: .response,
            messageType: request.messageType,
            sequence: sequence,
            isFinal: true,
            payload: FindOperations.encode([])
        )
        try Self.write(envelope: final, outputLock: outputLock)
    }

    static func encodeError(_ error: Error) -> Data {
        var writer = ServerRPCBinaryWriter()
        writer.writeString(String(describing: error))
        writer.writeString(FileOperations.isMissingFileError(error) ? "notFound" : "other")
        return writer.data
    }

    private static func write(envelope: ServerRPCEnvelope, outputLock: NSLock) throws {
        let frame = try ServerRPCStreamHandler.encodeFrame(envelope.encodedPayload())
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(frame)
    }

    private static func readFrame(from input: FileHandle) throws -> Data? {
        let lengthBytes = ExactFileHandleReader.read(4, from: input)
        guard !lengthBytes.isEmpty else { return nil }
        guard lengthBytes.count == 4 else {
            throw ServerRPCProtocolError.truncatedMessage
        }
        let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length <= ServerRPCStreamHandler.defaultMaxFrameSize else {
            throw ServerRPCProtocolError.frameTooLarge(length)
        }
        let payload = ExactFileHandleReader.read(length, from: input)
        guard payload.count == length else {
            throw ServerRPCProtocolError.truncatedMessage
        }
        return payload
    }

    private static func encodeWatchEvent(_ event: ServerWatchEvent) -> Data {
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt8(18)
        writer.writeString(event.token.uuidString)
        writer.writeUInt8(event.kind.rawValue)
        writer.writeData(Data(event.path.utf8))
        return writer.data
    }
}

private final class EventPump: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
