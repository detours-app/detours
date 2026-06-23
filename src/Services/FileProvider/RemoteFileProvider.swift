import Foundation

enum RemoteFileProviderError: Error, Equatable, LocalizedError {
    case expectedRemote(Location)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .expectedRemote:
            return "Expected a remote location."
        case .invalidResponse(let message):
            return message
        }
    }
}

protocol RemoteRPCClient: Sendable {
    func send(_ message: RPCMessage) async throws -> [Data]
}

actor SSHRemoteRPCClient: RemoteRPCClient {
    private struct PendingResponse {
        var assembler = RPCResponseAssembler()
        let continuation: CheckedContinuation<[Data], Error>
    }

    private let connection: SSHConnection
    private var nextRequestID: UInt64 = 1
    private var pendingResponses: [UInt64: PendingResponse] = [:]
    private var eventHandler: (@Sendable (RPCEnvelope) -> Void)?
    private var readerTask: Task<Void, Never>?
    private var readerGeneration: UInt64 = 0
    private var readerStreamGeneration: UInt64?

    init(connection: SSHConnection) {
        self.connection = connection
    }

    deinit {
        readerTask?.cancel()
    }

    func setEventHandler(_ handler: @escaping @Sendable (RPCEnvelope) -> Void) async {
        await startReaderIfNeeded()
        eventHandler = handler
    }

    func prepareForReconnect() {
        readerGeneration += 1
        readerTask?.cancel()
        readerTask = nil
        readerStreamGeneration = nil
        failAllResponses(CancellationError())
    }

    func send(_ message: RPCMessage) async throws -> [Data] {
        let requestID = nextRequestID
        nextRequestID += 1

        let envelope = RPCEnvelope(
            id: requestID,
            kind: .request,
            messageType: message.messageType,
            sequence: 0,
            isFinal: true,
            payload: try message.binaryEncoded()
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingResponses[requestID] = PendingResponse(continuation: continuation)
                Task {
                    do {
                        try await connection.send(envelope)
                        await self.startReaderIfNeeded()
                    } catch {
                        self.failResponse(id: requestID, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failResponse(id: requestID, error: CancellationError()) }
        }
    }

    private func readResponses(generation: UInt64) async {
        defer {
            if readerGeneration == generation {
                readerTask = nil
                readerStreamGeneration = nil
            }
        }

        while !Task.isCancelled {
            do {
                let envelope = try await connection.receive()
                guard readerGeneration == generation else { return }
                receive(envelope)
            } catch {
                if readerGeneration == generation {
                    failAllResponses(error)
                }
                return
            }
        }
    }

    private func startReaderIfNeeded() async {
        let streamGeneration = await connection.currentStreamGeneration()
        if readerTask != nil, readerStreamGeneration == streamGeneration {
            return
        }
        readerGeneration += 1
        let generation = readerGeneration
        readerTask?.cancel()
        readerStreamGeneration = streamGeneration
        readerTask = Task { [weak self] in
            await self?.readResponses(generation: generation)
        }
    }

    private func receive(_ envelope: RPCEnvelope) {
        if envelope.kind == .event {
            eventHandler?(envelope)
            return
        }

        guard var pending = pendingResponses[envelope.id] else { return }
        if envelope.kind == .error {
            pendingResponses.removeValue(forKey: envelope.id)?
                .continuation
                .resume(throwing: RemoteFileProviderError.invalidResponse(Self.decodeError(envelope.payload)))
            return
        }

        if let assembled = pending.assembler.receive(envelope) {
            pendingResponses.removeValue(forKey: envelope.id)?
                .continuation
                .resume(returning: assembled.chunks)
        } else {
            pendingResponses[envelope.id] = pending
        }
    }

    private func failResponse(id: UInt64, error: Error) {
        pendingResponses.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    private func failAllResponses(_ error: Error) {
        let responses = pendingResponses
        pendingResponses.removeAll()
        for response in responses.values {
            response.continuation.resume(throwing: error)
        }
    }

    private static func decodeError(_ payload: Data) -> String {
        var reader = RPCBinaryReader(data: payload)
        if let message = try? reader.readString(), !message.isEmpty {
            return message
        }
        return "The remote server reported an error."
    }

    #if DEBUG
    func simulateReaderForTesting(streamGeneration: UInt64) {
        readerTask = Task {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {}
        }
        readerStreamGeneration = streamGeneration
    }

    func readerStateForTesting() -> (generation: UInt64, streamGeneration: UInt64?, hasReaderTask: Bool) {
        (readerGeneration, readerStreamGeneration, readerTask != nil)
    }
    #endif
}

struct RemoteFileEntry: Equatable, Sendable {
    let path: RemotePath
    let name: Data
    let isDirectory: Bool
    let isPackage: Bool
    let isAliasFile: Bool
    let isSymbolicLink: Bool
    let isReadable: Bool
    let isHidden: Bool
    let fileSize: Int64?
    let contentModificationDate: Date

    init(
        path: RemotePath,
        name: Data,
        isDirectory: Bool,
        isPackage: Bool = false,
        isAliasFile: Bool = false,
        isSymbolicLink: Bool = false,
        isReadable: Bool = true,
        isHidden: Bool = false,
        fileSize: Int64? = nil,
        contentModificationDate: Date = Date()
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAliasFile = isAliasFile
        self.isSymbolicLink = isSymbolicLink
        self.isReadable = isReadable
        self.isHidden = isHidden
        self.fileSize = fileSize
        self.contentModificationDate = contentModificationDate
    }

    func loadedEntry(hostID: UUID) -> LoadedFileEntry {
        let pathString = path.lossyDisplayString
        return LoadedFileEntry(
            location: .remote(hostID: hostID, path: pathString),
            url: URL(fileURLWithPath: pathString),
            // Remote names are byte-exact on the wire; decoding for display is intentionally lossy.
            // swiftlint:disable:next optional_data_string_conversion
            name: String(decoding: name, as: UTF8.self),
            isDirectory: isDirectory,
            isPackage: isPackage,
            isAliasFile: isAliasFile,
            isSymbolicLink: isSymbolicLink,
            isReadable: isReadable,
            isHidden: isHidden,
            fileSize: fileSize,
            contentModificationDate: contentModificationDate
        )
    }
}

struct RemotePathListResponse: Equatable, Sendable {
    let paths: [RemotePath]
}

/// A single name-search hit: a byte-exact remote path plus whether it is a directory.
/// The wire shape (count, then per-match length-prefixed path bytes + is-directory bool)
/// is mirrored byte-for-byte by the server's FindOperations encoder.
struct RemoteFindMatch: Equatable, Sendable {
    let path: RemotePath
    let isDirectory: Bool
}

enum RemoteFindCodec {
    static func encode(_ matches: [RemoteFindMatch]) -> Data {
        var writer = RPCBinaryWriter()
        writer.writeUInt32(UInt32(matches.count))
        for match in matches {
            writer.writeData(match.path.bytes)
            writer.writeBool(match.isDirectory)
        }
        return writer.data
    }

    static func decode(_ data: Data) throws -> [RemoteFindMatch] {
        var reader = RPCBinaryReader(data: data)
        let count = Int(try reader.readUInt32())
        var matches: [RemoteFindMatch] = []
        matches.reserveCapacity(count)
        for _ in 0..<count {
            let path = RemotePath(bytes: try reader.readData())
            let isDirectory = try reader.readBool()
            matches.append(RemoteFindMatch(path: path, isDirectory: isDirectory))
        }
        try reader.requireComplete()
        return matches
    }
}

actor RemoteFileProvider: FileProvider {
    let hostID: UUID

    private let rpcClient: RemoteRPCClient
    private let transferChannel: RemoteTransferChannel
    private let watcherClient: RemoteWatcherClient?
    private let searchChannel: RemoteSearchChannel?
    private var watchers: [FileProviderWatch: UUID] = [:]
    private var rawPaths: [Location: RemotePath] = [:]

    init(
        hostID: UUID,
        rpcClient: RemoteRPCClient,
        transferChannel: RemoteTransferChannel,
        watcherClient: RemoteWatcherClient? = nil,
        searchChannel: RemoteSearchChannel? = nil
    ) {
        self.hostID = hostID
        self.rpcClient = rpcClient
        self.transferChannel = transferChannel
        self.watcherClient = watcherClient
        self.searchChannel = searchChannel
    }

    nonisolated func find(query: String, cap: Int) -> AsyncThrowingStream<[FoundItem], Error> {
        let hostID = self.hostID
        let rpcClient = self.rpcClient

        // Preferred path: a dedicated, killable search process that streams matches as they are found
        // and never blocks the persistent connection.
        if let searchChannel {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await batch in searchChannel.search(query: Data(query.utf8), cap: Int64(cap)) {
                            try Task.checkCancellation()
                            continuation.yield(batch.map { match in
                                FoundItem(
                                    location: .remote(hostID: hostID, path: match.path.lossyDisplayString),
                                    isDirectory: match.isDirectory
                                )
                            })
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // Fallback (e.g. tests without a search channel): one-shot find over the shared RPC connection.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chunks = try await rpcClient.send(.find(query: Data(query.utf8), cap: Int64(cap)))
                    for chunk in chunks {
                        let items = try RemoteFindCodec.decode(chunk).map { match in
                            FoundItem(
                                location: .remote(hostID: hostID, path: match.path.lossyDisplayString),
                                isDirectory: match.isDirectory
                            )
                        }
                        if !items.isEmpty {
                            continuation.yield(items)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        var entries: [LoadedFileEntry] = []
        for try await chunk in listChunks(location, showHidden: showHidden) {
            entries.append(contentsOf: chunk)
        }
        return entries
    }

    func listChunks(_ location: Location, showHidden: Bool) -> AsyncThrowingStream<[LoadedFileEntry], Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let chunks = try await rpcClient.send(.list(path: remotePath(from: location), showHidden: showHidden))
                    for chunk in chunks {
                        let entries = try Self.decodeFileEntries(chunk).map { entry in
                            self.loadedEntry(entry)
                        }
                        continuation.yield(entries)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        let chunks = try await rpcClient.send(.stat(path: remotePath(from: location)))
        guard chunks.count == 1, let entry = try Self.decodeFileEntries(chunks[0]).first else {
            throw RemoteFileProviderError.invalidResponse("stat")
        }
        return loadedEntry(entry)
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        let message = RPCMessage.copy(
            sources: try sources.map(remotePath(from:)),
            destination: try remotePath(from: destination),
            maximumRPCBytes: RemoteTransferChannel.rpcThresholdBytes
        )
        return try decodeLocations(from: try await rpcClient.send(message))
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        try decodeLocations(
            from: try await rpcClient.send(
                .move(sources: try sources.map(remotePath(from:)), destination: remotePath(from: destination))
            )
        )
    }

    func delete(_ items: [Location]) async throws {
        _ = try await rpcClient.send(.delete(items: try items.map(remotePath(from:))))
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        let paths = try decodePathList(from: try await rpcClient.send(.trash(items: try items.map(remotePath(from:)))))
        return zip(items, paths).map { item, trashPath in
            TrashedItem(originalLocation: item, trashLocation: .remote(hostID: hostID, path: trashPath.lossyDisplayString))
        }
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        try decodeLocations(
            from: try await rpcClient.send(.restoreFromTrash(items: items.map { remotePath(fromTrash: $0) }))
        )
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        let paths = try decodePathList(
            from: try await rpcClient.send(.rename(item: remotePath(from: item), newName: Data(newName.utf8)))
        )
        guard let path = paths.first else {
            throw RemoteFileProviderError.invalidResponse("rename")
        }
        return .remote(hostID: hostID, path: path.lossyDisplayString)
    }

    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        let paths = try decodePathList(
            from: try await rpcClient.send(
                .archiveCreate(
                    items: try items.map(remotePath(from:)),
                    format: format.rawValue,
                    archiveName: Data(archiveName.utf8),
                    password: password
                )
            )
        )
        guard let path = paths.first else {
            throw RemoteFileProviderError.invalidResponse("archiveCreate")
        }
        return .remote(hostID: hostID, path: path.lossyDisplayString)
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        let paths = try decodePathList(
            from: try await rpcClient.send(.archiveExtract(archive: remotePath(from: archive), password: password))
        )
        guard let path = paths.first else {
            throw RemoteFileProviderError.invalidResponse("archiveExtract")
        }
        return .remote(hostID: hostID, path: path.lossyDisplayString)
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        if let watcherClient {
            return try await watcherClient.watch(location, onChange: onChange)
        }

        throw FileProviderError.unsupportedOperation("Remote watcher events require a watcher client")
    }

    func unwatch(_ watch: FileProviderWatch) async {
        if let watcherClient {
            await watcherClient.unwatch(watch)
            return
        }

        guard let remoteToken = watchers.removeValue(forKey: watch) else { return }
        _ = try? await rpcClient.send(.unwatch(token: remoteToken))
    }

    func gitStatus(for directory: Location) async -> [Location: GitStatus] {
        guard let chunks = try? await rpcClient.send(.gitStatus(directory: remotePath(from: directory))),
              let payload = chunks.first,
              let statuses = try? Self.decodeGitStatuses(payload, hostID: hostID) else {
            return [:]
        }
        return statuses
    }

    func folderSize(for location: Location) async throws -> Int64 {
        let chunks = try await rpcClient.send(.folderSize(path: remotePath(from: location)))
        guard chunks.count == 1 else {
            throw RemoteFileProviderError.invalidResponse("folderSize")
        }
        var reader = RPCBinaryReader(data: chunks[0])
        let size = try reader.readInt64()
        try reader.requireComplete()
        return size
    }

    func readSymlink(_ location: Location) async throws -> Location {
        let paths = try decodePathList(from: try await rpcClient.send(.readSymlink(path: remotePath(from: location))))
        guard let path = paths.first else {
            throw RemoteFileProviderError.invalidResponse("readSymlink")
        }
        return .remote(hostID: hostID, path: path.lossyDisplayString)
    }

    func openForQuickLook(_ location: Location) async throws -> URL {
        let entry = try await stat(location)
        guard let size = entry.fileSize else {
            throw FileProviderError.unsupportedOperation("quick look directory")
        }
        guard size <= RemoteFileCache.quickLookMaximumBytes else {
            throw FileProviderError.unsupportedOperation("Remote Quick Look supports files up to 100 MB")
        }
        let destination = try RemoteFileCache.makeSessionFile(hostID: hostID, remotePath: remotePath(from: location).lossyDisplayString)
        try await download(location, to: destination, knownByteCount: size)
        return destination
    }

    func download(_ location: Location, to localURL: URL) async throws {
        try await download(location, to: localURL, knownByteCount: nil)
    }

    private func download(_ location: Location, to localURL: URL, knownByteCount: Int64?) async throws {
        let path = try remotePath(from: location)
        let byteCount: Int64
        if let knownByteCount {
            byteCount = knownByteCount
        } else {
            let entry = try await stat(location)
            byteCount = entry.fileSize ?? 0
        }
        if transferRoute(forByteCount: byteCount) == .transferChannel {
            try await transferChannel.download(source: path, expectedByteCount: byteCount, to: localURL)
            return
        }

        let chunks = try await rpcClient.send(.download(path: path, maximumRPCBytes: RemoteTransferChannel.rpcThresholdBytes))
        guard chunks.count == 1 else {
            throw RemoteFileProviderError.invalidResponse("download")
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = RemoteTransferChannel.partialURL(for: localURL)
        try? FileManager.default.removeItem(at: partial)
        guard !FileManager.default.fileExists(atPath: localURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        do {
            try chunks[0].write(to: partial, options: .atomic)
            try FileManager.default.moveItem(at: partial, to: localURL)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = Int64(values.fileSize ?? 0)
        if transferRoute(forByteCount: byteCount) == .transferChannel {
            try await transferChannel.upload(source: localURL, destination: remotePath(from: location), byteCount: byteCount)
            return
        }

        let data = try Data(contentsOf: localURL)
        _ = try await rpcClient.send(
            .upload(
                path: remotePath(from: location),
                contents: data,
                expectedByteCount: byteCount,
                maximumRPCBytes: RemoteTransferChannel.rpcThresholdBytes
            )
        )
    }

    func version(of location: Location) async throws -> RemoteFileVersion {
        let chunks = try await rpcClient.send(.fileVersion(path: remotePath(from: location)))
        guard chunks.count == 1 else {
            throw RemoteFileProviderError.invalidResponse("fileVersion")
        }
        var reader = RPCBinaryReader(data: chunks[0])
        let sha256 = try reader.readString()
        let mtimeMilliseconds = try reader.readInt64()
        try reader.requireComplete()
        return RemoteFileVersion(
            sha256: sha256,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(mtimeMilliseconds) / 1_000)
        )
    }

    func transferRoute(forByteCount byteCount: Int64) -> RemoteTransferRoute {
        RemoteTransferChannel.route(forByteCount: byteCount)
    }

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

    private func remotePath(from location: Location) throws -> RemotePath {
        guard case .remote(let locationHostID, let path) = location, locationHostID == hostID else {
            throw RemoteFileProviderError.expectedRemote(location)
        }
        return rawPaths[location] ?? RemotePath(path)
    }

    private func remotePath(fromTrash item: TrashedItem) -> RemotePath {
        if case .remote(_, let path) = item.trashLocation {
            return RemotePath(path)
        }
        return RemotePath("")
    }

    private func decodeLocations(from response: [Data]) throws -> [Location] {
        try decodePathList(from: response).map { path in
            let location = Location.remote(hostID: hostID, path: path.lossyDisplayString)
            rawPaths[location] = path
            return location
        }
    }

    private func decodePathList(from response: [Data]) throws -> [RemotePath] {
        guard response.count == 1 else {
            throw RemoteFileProviderError.invalidResponse("path list")
        }
        return try Self.decodePathList(response[0]).paths
    }

    private static func decodeFileEntries(_ data: Data) throws -> [RemoteFileEntry] {
        var reader = RPCBinaryReader(data: data)
        let count = Int(try reader.readUInt32())
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

    private func loadedEntry(_ entry: RemoteFileEntry) -> LoadedFileEntry {
        let loaded = entry.loadedEntry(hostID: hostID)
        rawPaths[loaded.location] = entry.path
        return loaded
    }

    private static func decodePathList(_ data: Data) throws -> RemotePathListResponse {
        var reader = RPCBinaryReader(data: data)
        let count = Int(try reader.readUInt32())
        var paths: [RemotePath] = []
        paths.reserveCapacity(count)
        for _ in 0..<count {
            paths.append(RemotePath(bytes: try reader.readData()))
        }
        try reader.requireComplete()
        return RemotePathListResponse(paths: paths)
    }

    private static func decodeGitStatuses(_ data: Data, hostID: UUID) throws -> [Location: GitStatus] {
        var reader = RPCBinaryReader(data: data)
        let count = Int(try reader.readUInt32())
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

extension RPCMessage {
    var messageType: String {
        switch self {
        case .protocolVersion: return "ProtocolVersion"
        case .list: return "List"
        case .stat: return "Stat"
        case .copy: return "Copy"
        case .move: return "Move"
        case .rename: return "Rename"
        case .delete: return "Delete"
        case .trash: return "Trash"
        case .restoreFromTrash: return "RestoreFromTrash"
        case .mkDir: return "MkDir"
        case .readSymlink: return "ReadSymlink"
        case .folderSize: return "FolderSize"
        case .gitStatus: return "GitStatus"
        case .archiveCreate: return "ArchiveCreate"
        case .archiveExtract: return "ArchiveExtract"
        case .fileVersion: return "FileVersion"
        case .download: return "Download"
        case .upload: return "Upload"
        case .watch: return "Watch"
        case .unwatch: return "Unwatch"
        case .watchEvent: return "WatchEvent"
        case .find: return "Find"
        }
    }
}
