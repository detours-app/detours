import Foundation

extension RemoteFileProvider {
    static func encodeFileEntries(_ entries: [RemoteFileEntry]) -> Data {
        var writer = RPCBinaryWriter()
        writer.writeUInt32(UInt32(entries.count))
        for entry in entries {
            writer.writeData(entry.path.bytes)
            writer.writeData(entry.name)
            writer.writeBool(entry.isDirectory)
            writer.writeBool(entry.isPackage)
            writer.writeBool(entry.isAliasFile)
            writer.writeBool(entry.isSymbolicLink)
            writer.writeBool(entry.isReadable)
            writer.writeBool(entry.isHidden)
            writer.writeBool(entry.fileSize != nil)
            if let fileSize = entry.fileSize {
                writer.writeInt64(fileSize)
            }
            writer.writeInt64(Int64(entry.contentModificationDate.timeIntervalSince1970 * 1_000))
        }
        return writer.data
    }

    static func encodePathList(_ paths: [RemotePath]) -> Data {
        var writer = RPCBinaryWriter()
        writer.writeUInt32(UInt32(paths.count))
        for path in paths {
            writer.writeData(path.bytes)
        }
        return writer.data
    }

    func remotePath(from location: Location) throws -> RemotePath {
        guard case .remote(let locationHostID, let path) = location, locationHostID == hostID else {
            throw RemoteFileProviderError.expectedRemote(location)
        }
        return rawPaths[location] ?? RemotePath(path)
    }

    func remotePath(fromTrash item: TrashedItem) -> RemotePath {
        if case .remote(_, let path) = item.trashLocation {
            return RemotePath(path)
        }
        return RemotePath("")
    }

    func decodeLocations(from response: [Data]) throws -> [Location] {
        try decodePathList(from: response).map { path in
            let location = Location.remote(hostID: hostID, path: path.lossyDisplayString)
            rawPaths[location] = path
            return location
        }
    }

    func decodePathList(from response: [Data]) throws -> [RemotePath] {
        guard response.count == 1 else {
            throw RemoteFileProviderError.invalidResponse("path list")
        }
        return try Self.decodePathList(response[0]).paths
    }

    static func decodeFileEntries(_ data: Data) throws -> [RemoteFileEntry] {
        var reader = RPCBinaryReader(data: data)
        let count = try reader.readBoundedCount(minimumBytesPerElement: 23)
        var entries: [RemoteFileEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let path = RemotePath(bytes: try reader.readData())
            let name = try reader.readData()
            let isDirectory = try reader.readBool()
            let isPackage = try reader.readBool()
            let isAliasFile = try reader.readBool()
            let isSymbolicLink = try reader.readBool()
            let isReadable = try reader.readBool()
            let isHidden = try reader.readBool()
            let hasFileSize = try reader.readBool()
            let fileSize = hasFileSize ? try reader.readInt64() : nil
            let mtimeMilliseconds = try reader.readInt64()
            entries.append(
                RemoteFileEntry(
                    path: path,
                    name: name,
                    isDirectory: isDirectory,
                    isPackage: isPackage,
                    isAliasFile: isAliasFile,
                    isSymbolicLink: isSymbolicLink,
                    isReadable: isReadable,
                    isHidden: isHidden,
                    fileSize: fileSize,
                    contentModificationDate: Date(timeIntervalSince1970: TimeInterval(mtimeMilliseconds) / 1_000)
                )
            )
        }
        try reader.requireComplete()
        return entries
    }

    func loadedEntry(_ entry: RemoteFileEntry) -> LoadedFileEntry {
        let loaded = entry.loadedEntry(hostID: hostID)
        rawPaths[loaded.location] = entry.path
        return loaded
    }

    private static func decodePathList(_ data: Data) throws -> RemotePathListResponse {
        var reader = RPCBinaryReader(data: data)
        let count = try reader.readBoundedCount(minimumBytesPerElement: 4)
        var paths: [RemotePath] = []
        paths.reserveCapacity(count)
        for _ in 0..<count {
            paths.append(RemotePath(bytes: try reader.readData()))
        }
        try reader.requireComplete()
        return RemotePathListResponse(paths: paths)
    }

    static func decodeGitStatuses(_ data: Data, hostID: UUID) throws -> [Location: GitStatus] {
        var reader = RPCBinaryReader(data: data)
        let count = try reader.readBoundedCount(minimumBytesPerElement: 8)
        var statuses: [Location: GitStatus] = [:]
        for _ in 0..<count {
            let path = RemotePath(bytes: try reader.readData())
            guard let status = GitStatus(rawValue: try reader.readString()) else {
                throw RemoteFileProviderError.invalidResponse("gitStatus")
            }
            statuses[.remote(hostID: hostID, path: path.lossyDisplayString)] = status
        }
        try reader.requireComplete()
        return statuses
    }
}
