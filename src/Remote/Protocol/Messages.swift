import Foundation

struct RemotePath: Equatable, Hashable, Sendable {
    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    init(_ path: String) {
        self.bytes = Data(path.utf8)
    }

    var lossyDisplayString: String {
        // Remote paths are byte-exact on the wire; decoding for display is intentionally lossy.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}

enum RemoteWatchEventKind: UInt8, Equatable, Sendable {
    case created = 1
    case modified = 2
    case deleted = 3
    case renamed = 4
}

enum RPCMessage: Equatable, Sendable {
    case protocolVersion(Int)
    case list(path: RemotePath, showHidden: Bool)
    case stat(path: RemotePath)
    case copy(sources: [RemotePath], destination: RemotePath, maximumRPCBytes: Int64)
    case move(sources: [RemotePath], destination: RemotePath)
    case rename(item: RemotePath, newName: Data)
    case delete(items: [RemotePath])
    case trash(items: [RemotePath])
    case restoreFromTrash(items: [RemotePath])
    case mkDir(path: RemotePath)
    case readSymlink(path: RemotePath)
    case folderSize(path: RemotePath)
    case gitStatus(directory: RemotePath)
    case archiveCreate(items: [RemotePath], format: String, archiveName: Data, password: String?)
    case archiveExtract(archive: RemotePath, password: String?)
    case fileVersion(path: RemotePath)
    case download(path: RemotePath, maximumRPCBytes: Int64)
    case upload(path: RemotePath, contents: Data, expectedByteCount: Int64, maximumRPCBytes: Int64)
    case watch(path: RemotePath, token: UUID)
    case unwatch(token: UUID)
    case watchEvent(watch: UUID, kind: RemoteWatchEventKind, path: RemotePath)
    case find(query: Data, cap: Int64)

    func binaryEncoded() throws -> Data {
        var writer = RPCBinaryWriter()

        switch self {
        case .protocolVersion(let version):
            writer.writeUInt8(1)
            writer.writeInt64(Int64(version))
        case .list(let path, let showHidden):
            writer.writeUInt8(2)
            writer.writeRemotePath(path)
            writer.writeBool(showHidden)
        case .stat(let path):
            writer.writeUInt8(3)
            writer.writeRemotePath(path)
        case .copy(let sources, let destination, let maximumRPCBytes):
            writer.writeUInt8(4)
            writer.writeRemotePaths(sources)
            writer.writeRemotePath(destination)
            writer.writeInt64(maximumRPCBytes)
        case .move(let sources, let destination):
            writer.writeUInt8(5)
            writer.writeRemotePaths(sources)
            writer.writeRemotePath(destination)
        case .rename(let item, let newName):
            writer.writeUInt8(6)
            writer.writeRemotePath(item)
            writer.writeData(newName)
        case .delete(let items):
            writer.writeUInt8(7)
            writer.writeRemotePaths(items)
        case .trash(let items):
            writer.writeUInt8(8)
            writer.writeRemotePaths(items)
        case .restoreFromTrash(let items):
            writer.writeUInt8(9)
            writer.writeRemotePaths(items)
        case .mkDir(let path):
            writer.writeUInt8(10)
            writer.writeRemotePath(path)
        case .readSymlink(let path):
            writer.writeUInt8(11)
            writer.writeRemotePath(path)
        case .folderSize(let path):
            writer.writeUInt8(12)
            writer.writeRemotePath(path)
        case .gitStatus(let directory):
            writer.writeUInt8(13)
            writer.writeRemotePath(directory)
        case .archiveCreate(let items, let format, let archiveName, let password):
            writer.writeUInt8(14)
            writer.writeRemotePaths(items)
            writer.writeString(format)
            writer.writeData(archiveName)
            writer.writeOptionalString(password)
        case .archiveExtract(let archive, let password):
            writer.writeUInt8(15)
            writer.writeRemotePath(archive)
            writer.writeOptionalString(password)
        case .fileVersion(let path):
            writer.writeUInt8(19)
            writer.writeRemotePath(path)
        case .download(let path, let maximumRPCBytes):
            writer.writeUInt8(20)
            writer.writeRemotePath(path)
            writer.writeInt64(maximumRPCBytes)
        case .upload(let path, let contents, let expectedByteCount, let maximumRPCBytes):
            writer.writeUInt8(21)
            writer.writeRemotePath(path)
            writer.writeData(contents)
            writer.writeInt64(expectedByteCount)
            writer.writeInt64(maximumRPCBytes)
        case .watch(let path, let token):
            writer.writeUInt8(16)
            writer.writeRemotePath(path)
            writer.writeUUID(token)
        case .unwatch(let token):
            writer.writeUInt8(17)
            writer.writeUUID(token)
        case .watchEvent(let watch, let kind, let path):
            writer.writeUInt8(18)
            writer.writeUUID(watch)
            writer.writeUInt8(kind.rawValue)
            writer.writeRemotePath(path)
        case .find(let query, let cap):
            writer.writeUInt8(22)
            writer.writeData(query)
            writer.writeInt64(cap)
        }

        return writer.data
    }

    init(binaryEncoded data: Data) throws {
        var reader = RPCBinaryReader(data: data)
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
        case 16:
            self = .watch(path: try reader.readRemotePath(), token: try reader.readUUID())
        case 17:
            self = .unwatch(token: try reader.readUUID())
        case 18:
            let watch = try reader.readUUID()
            let kindByte = try reader.readUInt8()
            guard let kind = RemoteWatchEventKind(rawValue: kindByte) else {
                throw RPCProtocolError.invalidMessage
            }
            self = .watchEvent(watch: watch, kind: kind, path: try reader.readRemotePath())
        case 22:
            self = .find(query: try reader.readData(), cap: try reader.readInt64())
        default:
            throw RPCProtocolError.unexpectedMessageTag(tag)
        }

        try reader.requireComplete()
    }
}

private extension RPCBinaryWriter {
    mutating func writeRemotePath(_ path: RemotePath) {
        writeData(path.bytes)
    }

    mutating func writeRemotePaths(_ paths: [RemotePath]) {
        writeUInt32(UInt32(paths.count))
        for path in paths {
            writeRemotePath(path)
        }
    }
}

private extension RPCBinaryReader {
    mutating func readRemotePath() throws -> RemotePath {
        RemotePath(bytes: try readData())
    }

    mutating func readRemotePaths() throws -> [RemotePath] {
        let count = Int(try readUInt32())
        var paths: [RemotePath] = []
        paths.reserveCapacity(count)
        for _ in 0..<count {
            paths.append(try readRemotePath())
        }
        return paths
    }
}
