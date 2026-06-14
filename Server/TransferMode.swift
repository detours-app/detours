import Foundation

enum TransferModeError: Error, Equatable {
    case byteCountMismatch(expected: Int64, actual: Int64)
    case invalidDirection(UInt8)
    case invalidHandshake
}

private enum TransferDirection: UInt8 {
    case upload = 1
    case download = 2
}

private struct TransferHandshake {
    let direction: TransferDirection
    let source: ServerRemotePath
    let destination: ServerRemotePath
    let byteCount: Int64

    init(binaryEncoded data: Data) throws {
        var reader = ServerRPCBinaryReader(data: data)
        let directionByte = try reader.readUInt8()
        guard let direction = TransferDirection(rawValue: directionByte) else {
            throw TransferModeError.invalidDirection(directionByte)
        }
        self.direction = direction
        self.source = ServerRemotePath(bytes: try reader.readData())
        self.destination = ServerRemotePath(bytes: try reader.readData())
        self.byteCount = try reader.readInt64()
        try reader.requireComplete()
    }
}

struct TransferMode {
    private let input: FileHandle
    private let output: FileHandle
    private let fileManager: FileManager
    private let trashOperations: TrashOperations

    init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        fileManager: FileManager = .default,
        trashOperations: TrashOperations = TrashOperations()
    ) {
        self.input = input
        self.output = output
        self.fileManager = fileManager
        self.trashOperations = trashOperations
    }

    func run() throws {
        let handshake = try TransferHandshake(binaryEncoded: readFrame())
        switch handshake.direction {
        case .download:
            try streamDownload(handshake)
        case .upload:
            try receiveUpload(handshake)
        }
    }

    private func streamDownload(_ handshake: TransferHandshake) throws {
        let source = URL(fileURLWithPath: handshake.source.string)
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount == handshake.byteCount else {
            throw TransferModeError.byteCountMismatch(expected: handshake.byteCount, actual: byteCount)
        }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var streamed: Int64 = 0
        while streamed < handshake.byteCount {
            let chunk = handle.readData(ofLength: min(64 * 1024, Int(handshake.byteCount - streamed)))
            guard !chunk.isEmpty else { break }
            output.write(chunk)
            streamed += Int64(chunk.count)
        }
        guard streamed == handshake.byteCount else {
            throw TransferModeError.byteCountMismatch(expected: handshake.byteCount, actual: streamed)
        }
    }

    private func receiveUpload(_ handshake: TransferHandshake) throws {
        let destination = URL(fileURLWithPath: handshake.destination.string)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".detours-partial")
        try? fileManager.removeItem(at: partial)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try trashOperations.trash(paths: [destination.path])
        }
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var received: Int64 = 0
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }

            while received < handshake.byteCount {
                let chunk = input.readData(ofLength: min(64 * 1024, Int(handshake.byteCount - received)))
                guard !chunk.isEmpty else { break }
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
            }

            guard received == handshake.byteCount else {
                throw TransferModeError.byteCountMismatch(expected: handshake.byteCount, actual: received)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private func readFrame() throws -> Data {
        let lengthBytes = input.readData(ofLength: 4)
        guard lengthBytes.count == 4 else {
            throw TransferModeError.invalidHandshake
        }
        let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let payload = input.readData(ofLength: length)
        guard payload.count == length else {
            throw TransferModeError.invalidHandshake
        }
        return payload
    }
}
