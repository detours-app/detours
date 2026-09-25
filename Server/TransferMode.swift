import DetoursProcess
import Foundation
import RemoteOperationSupport

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
        guard byteCount >= 0 else {
            throw TransferModeError.invalidHandshake
        }
        try reader.requireComplete()
    }
}

struct TransferMode {
    private let input: FileHandle
    private let output: FileHandle
    private let operationService: ServerOperationService?

    init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        operationService: ServerOperationService? = nil
    ) {
        self.input = input
        self.output = output
        self.operationService = operationService
    }

    func run() throws {
        let frame = try readFrame()
        if frame.first == 3 {
            let handshake = try OperationStreamHandshake.decode(Data(frame.dropFirst()))
            let reply = try ServerOperationReplyBridge.stream(handshake.identity, input: input, service: operationService).encoded()
            var length = UInt32(reply.count).bigEndian
            try output.write(contentsOf: Data(bytes: &length, count: MemoryLayout<UInt32>.size) + reply)
            return
        }
        let handshake = try TransferHandshake(binaryEncoded: frame)
        switch handshake.direction {
        case .download:
            try streamDownload(handshake)
        case .upload:
            throw ServerRPCError.acceptedOperationRequired
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

    private func readFrame() throws -> Data {
        let lengthBytes = ExactFileHandleReader.read(4, from: input)
        guard lengthBytes.count == 4 else {
            throw TransferModeError.invalidHandshake
        }
        let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length <= ServerRPCStreamHandler.defaultMaxFrameSize else {
            throw TransferModeError.invalidHandshake
        }
        let payload = ExactFileHandleReader.read(length, from: input)
        guard payload.count == length else {
            throw TransferModeError.invalidHandshake
        }
        return payload
    }

}
