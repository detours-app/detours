import Foundation

enum RPCProtocolError: Error, Equatable {
    case frameTooLarge(Int)
    case invalidFrame
    case invalidMessage
    case truncatedMessage
    case unexpectedMessageTag(UInt8)
}

struct RPCEnvelope: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
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
}

struct RPCAssembledResponse: Equatable, Sendable {
    let id: UInt64
    let chunks: [Data]

    var payload: Data {
        chunks.reduce(into: Data()) { result, chunk in
            result.append(chunk)
        }
    }
}

struct RPCResponseAssembler {
    private var pending: [UInt64: [RPCEnvelope]] = [:]

    mutating func receive(_ envelope: RPCEnvelope) -> RPCAssembledResponse? {
        guard envelope.kind == .response else { return nil }

        var chunks = pending[envelope.id] ?? []
        chunks.append(envelope)

        guard envelope.isFinal else {
            pending[envelope.id] = chunks
            return nil
        }

        pending.removeValue(forKey: envelope.id)
        let ordered = chunks.sorted { $0.sequence < $1.sequence }
        return RPCAssembledResponse(id: envelope.id, chunks: ordered.map(\.payload))
    }
}

struct RPCStreamHandler {
    static let defaultMaxFrameSize = 16 * 1024 * 1024

    private let maxFrameSize: Int
    private var buffer = Data()

    init(maxFrameSize: Int = Self.defaultMaxFrameSize) {
        self.maxFrameSize = maxFrameSize
    }

    static func encodeFrame(_ payload: Data, maxFrameSize: Int = defaultMaxFrameSize) throws -> Data {
        guard payload.count <= maxFrameSize else {
            throw RPCProtocolError.frameTooLarge(payload.count)
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
                throw RPCProtocolError.frameTooLarge(length)
            }

            guard buffer.count >= 4 + length else { break }

            frames.append(buffer.subdata(in: 4..<(4 + length)))
            buffer.removeSubrange(0..<(4 + length))
        }

        return frames
    }
}

extension RPCEnvelope {
    func encodedPayload() -> Data {
        var writer = RPCBinaryWriter()
        writer.writeUInt64(id)
        writer.writeUInt8(kind.rawValue)
        writer.writeString(messageType)
        writer.writeUInt32(sequence)
        writer.writeBool(isFinal)
        writer.writeData(payload)
        return writer.data
    }

    init(encodedPayload data: Data) throws {
        var reader = RPCBinaryReader(data: data)
        let id = try reader.readUInt64()
        let kindByte = try reader.readUInt8()
        guard let kind = Kind(rawValue: kindByte) else {
            throw RPCProtocolError.invalidFrame
        }
        let messageType = try reader.readString()
        let sequence = try reader.readUInt32()
        let isFinal = try reader.readBool()
        let payload = try reader.readData()
        try reader.requireComplete()

        self.init(
            id: id,
            kind: kind,
            messageType: messageType,
            sequence: sequence,
            isFinal: isFinal,
            payload: payload
        )
    }
}

struct RPCBinaryWriter {
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

    mutating func writeOptionalString(_ value: String?) {
        writeBool(value != nil)
        if let value {
            writeString(value)
        }
    }

    mutating func writeUUID(_ value: UUID) {
        writeString(value.uuidString)
    }
}

struct RPCBinaryReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw RPCProtocolError.truncatedMessage
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return UInt32(bigEndianData: bytes)
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readData() throws -> Data {
        let length = Int(try readUInt32())
        return Data(try readBytes(count: length))
    }

    mutating func readString() throws -> String {
        let data = try readData()
        guard let value = String(data: data, encoding: .utf8) else {
            throw RPCProtocolError.invalidMessage
        }
        return value
    }

    mutating func readOptionalString() throws -> String? {
        try readBool() ? try readString() : nil
    }

    mutating func readUUID() throws -> UUID {
        guard let uuid = UUID(uuidString: try readString()) else {
            throw RPCProtocolError.invalidMessage
        }
        return uuid
    }

    mutating func requireComplete() throws {
        guard offset == data.count else {
            throw RPCProtocolError.invalidMessage
        }
    }

    private mutating func readBytes(count: Int) throws -> Data.SubSequence {
        guard count >= 0, offset + count <= data.count else {
            throw RPCProtocolError.truncatedMessage
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
