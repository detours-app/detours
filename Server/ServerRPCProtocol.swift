import Foundation

enum ServerRPCProtocolError: Error {
    case invalidFrame
    case truncatedMessage
    case unexpectedMessageTag(UInt8)
    case unsupportedMessage
    case frameTooLarge(Int)
}

struct ServerRemotePath: Equatable, Hashable {
    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    init(_ path: String) {
        self.bytes = Data(path.utf8)
    }

    var string: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

enum ServerRPCMessage {
    case protocolVersion(Int)
    case list(path: ServerRemotePath, showHidden: Bool)
    case stat(path: ServerRemotePath)
    case copy(sources: [ServerRemotePath], destination: ServerRemotePath, maximumRPCBytes: Int64)
    case move(sources: [ServerRemotePath], destination: ServerRemotePath)
    case rename(item: ServerRemotePath, newName: Data)
    case delete(items: [ServerRemotePath])
    case trash(items: [ServerRemotePath])
    case restoreFromTrash(items: [ServerRemotePath])
    case mkDir(path: ServerRemotePath)
    case archiveCreate(items: [ServerRemotePath], format: String, archiveName: Data, password: String?)
    case archiveExtract(archive: ServerRemotePath, password: String?)
    case watch(path: ServerRemotePath, token: UUID)
    case unwatch(token: UUID)
    case download(path: ServerRemotePath, maximumRPCBytes: Int64)
    case upload(path: ServerRemotePath, contents: Data, expectedByteCount: Int64, maximumRPCBytes: Int64)
    case fileVersion(path: ServerRemotePath)
    case readSymlink(path: ServerRemotePath)
    case folderSize(path: ServerRemotePath)
    case gitStatus(directory: ServerRemotePath)

    init(binaryEncoded data: Data) throws {
        var reader = ServerRPCBinaryReader(data: data)
        let tag = try reader.readUInt8()

        switch tag {
        case 1:
            self = .protocolVersion(Int(try reader.readInt64()))
        case 2:
            self = .list(path: try reader.readRemotePath(), showHidden: try reader.readBool())
        case 3:
            self = .stat(path: try reader.readRemotePath())
        case 4:
            self = .copy(
                sources: try reader.readRemotePaths(),
                destination: try reader.readRemotePath(),
                maximumRPCBytes: try reader.readInt64()
            )
        case 5:
            self = .move(sources: try reader.readRemotePaths(), destination: try reader.readRemotePath())
        case 6:
            self = .rename(item: try reader.readRemotePath(), newName: try reader.readData())
        case 7:
            self = .delete(items: try reader.readRemotePaths())
        case 8:
            self = .trash(items: try reader.readRemotePaths())
        case 9:
            self = .restoreFromTrash(items: try reader.readRemotePaths())
        case 10:
            self = .mkDir(path: try reader.readRemotePath())
        case 11:
            self = .readSymlink(path: try reader.readRemotePath())
        case 12:
            self = .folderSize(path: try reader.readRemotePath())
        case 13:
            self = .gitStatus(directory: try reader.readRemotePath())
        case 14:
            self = .archiveCreate(
                items: try reader.readRemotePaths(),
                format: try reader.readString(),
                archiveName: try reader.readData(),
                password: try reader.readOptionalString()
            )
        case 15:
            self = .archiveExtract(archive: try reader.readRemotePath(), password: try reader.readOptionalString())
        case 16:
            self = .watch(path: try reader.readRemotePath(), token: try reader.readUUID())
        case 17:
            self = .unwatch(token: try reader.readUUID())
        case 19:
            self = .fileVersion(path: try reader.readRemotePath())
        case 20:
            self = .download(path: try reader.readRemotePath(), maximumRPCBytes: try reader.readInt64())
        case 21:
            self = .upload(
                path: try reader.readRemotePath(),
                contents: try reader.readData(),
                expectedByteCount: try reader.readInt64(),
                maximumRPCBytes: try reader.readInt64()
            )
        default:
            throw ServerRPCProtocolError.unexpectedMessageTag(tag)
        }

        try reader.requireComplete()
    }
}

struct ServerRPCEnvelope {
    enum Kind: UInt8 {
        case request = 1
        case response = 2
        case event = 3
        case error = 4
    }

    let id: UInt64
    let kind: Kind
    let messageType: String
    let sequence: UInt32
    let isFinal: Bool
    let payload: Data

    func encodedPayload() -> Data {
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt64(id)
        writer.writeUInt8(kind.rawValue)
        writer.writeString(messageType)
        writer.writeUInt32(sequence)
        writer.writeBool(isFinal)
        writer.writeData(payload)
        return writer.data
    }

    init(encodedPayload data: Data) throws {
        var reader = ServerRPCBinaryReader(data: data)
        let id = try reader.readUInt64()
        let kindByte = try reader.readUInt8()
        guard let kind = Kind(rawValue: kindByte) else {
            throw ServerRPCProtocolError.invalidFrame
        }
        let messageType = try reader.readString()
        let sequence = try reader.readUInt32()
        let isFinal = try reader.readBool()
        let payload = try reader.readData()
        try reader.requireComplete()

        self.id = id
        self.kind = kind
        self.messageType = messageType
        self.sequence = sequence
        self.isFinal = isFinal
        self.payload = payload
    }

    init(id: UInt64, kind: Kind, messageType: String, sequence: UInt32, isFinal: Bool, payload: Data) {
        self.id = id
        self.kind = kind
        self.messageType = messageType
        self.sequence = sequence
        self.isFinal = isFinal
        self.payload = payload
    }
}

struct ServerRPCStreamHandler {
    static let defaultMaxFrameSize = 16 * 1024 * 1024

    private let maxFrameSize: Int
    private var buffer = Data()

    init(maxFrameSize: Int = Self.defaultMaxFrameSize) {
        self.maxFrameSize = maxFrameSize
    }

    static func encodeFrame(_ payload: Data, maxFrameSize: Int = defaultMaxFrameSize) throws -> Data {
        guard payload.count <= maxFrameSize else {
            throw ServerRPCProtocolError.frameTooLarge(payload.count)
        }
        var frame = Data()
        frame.append(UInt32(payload.count).bigEndianData)
        frame.append(payload)
        return frame
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= 4 {
            let length = Int(UInt32(bigEndianData: buffer.prefix(4)))
            guard length <= maxFrameSize else {
                throw ServerRPCProtocolError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }

            frames.append(buffer.subdata(in: 4..<(4 + length)))
            buffer.removeSubrange(0..<(4 + length))
        }

        return frames
    }
}

struct ServerRPCBinaryWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeBool(_ value: Bool) {
        writeUInt8(value ? 1 : 0)
    }

    mutating func writeUInt32(_ value: UInt32) {
        data.append(value.bigEndianData)
    }

    mutating func writeUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size))
    }

    mutating func writeInt64(_ value: Int64) {
        writeUInt64(UInt64(bitPattern: value))
    }

    mutating func writeData(_ value: Data) {
        writeUInt32(UInt32(value.count))
        data.append(value)
    }

    mutating func writeString(_ value: String) {
        writeData(Data(value.utf8))
    }
}

struct ServerRPCBinaryReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw ServerRPCProtocolError.truncatedMessage
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(bigEndianData: try readBytes(count: 4))
    }

    mutating func readUInt64() throws -> UInt64 {
        try readBytes(count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readData() throws -> Data {
        let length = Int(try readUInt32())
        return Data(try readBytes(count: length))
    }

    mutating func readString() throws -> String {
        String(decoding: try readData(), as: UTF8.self)
    }

    mutating func readUUID() throws -> UUID {
        guard let uuid = UUID(uuidString: try readString()) else {
            throw ServerRPCProtocolError.invalidFrame
        }
        return uuid
    }

    mutating func readOptionalString() throws -> String? {
        try readBool() ? try readString() : nil
    }

    mutating func readRemotePath() throws -> ServerRemotePath {
        ServerRemotePath(bytes: try readData())
    }

    mutating func readRemotePaths() throws -> [ServerRemotePath] {
        let count = Int(try readUInt32())
        var paths: [ServerRemotePath] = []
        paths.reserveCapacity(count)
        for _ in 0..<count {
            paths.append(try readRemotePath())
        }
        return paths
    }

    mutating func requireComplete() throws {
        guard offset == data.count else {
            throw ServerRPCProtocolError.invalidFrame
        }
    }

    private mutating func readBytes(count: Int) throws -> Data.SubSequence {
        guard count >= 0, offset + count <= data.count else {
            throw ServerRPCProtocolError.truncatedMessage
        }
        let range = offset..<(offset + count)
        offset += count
        return data[range]
    }
}

private extension UInt32 {
    var bigEndianData: Data {
        var bigEndian = self.bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
    }

    init(bigEndianData data: Data.SubSequence) {
        self = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
