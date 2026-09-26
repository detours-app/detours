import Foundation
import RemoteOperationSupport

actor WindowsRemoteProvider: FileProvider {
    let hostID: UUID

    private let channel: PowerShellChannel
    private let transferChannel: WindowsTransferChannel
    private let watchChannel: WindowsWatchChannel?
    private var rawPaths: [Location: String] = [:]
    private var watchLifetimes: [FileProviderWatch: RemoteSessionLifetime] = [:]

    func prepareAcceptedUpload(_ localURL: URL, identity: OperationRequestIdentity, sftpAvailable: Bool) async throws -> OperationReceipt {
        try await transferChannel.prepareAcceptedUpload(localURL: localURL, identity: identity, sftpAvailable: sftpAvailable)
    }

    func operationRequest(_ request: OperationRequest) async throws -> OperationReply {
        let lifetime = try await channel.acquireLifetime(.operation)
        defer { lifetime?.release() }
        let script = try PowerShellScript(source: WindowsOperationScripts.protocolScript, arguments: WindowsOperationArguments(request))
        switch request {
        case .status, .cancel:
            return try OperationReply.decode(await channel.runIndependent(script, operation: "OperationControl"))
        default:
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedOperation"))
        }
    }

    init(
        hostID: UUID,
        channel: PowerShellChannel,
        transferChannel: WindowsTransferChannel,
        watchChannel: WindowsWatchChannel? = nil
    ) {
        self.hostID = hostID
        self.channel = channel
        self.transferChannel = transferChannel
        self.watchChannel = watchChannel
    }

    init(hostID: UUID, sshTarget: String, channel: PowerShellChannel) {
        self.hostID = hostID
        self.channel = channel
        self.transferChannel = WindowsTransferChannel(sshTarget: sshTarget, powerShellChannel: channel)
        self.watchChannel = WindowsWatchChannel(hostID: hostID, sshTarget: sshTarget)
    }

    func homeDirectory() async throws -> String {
        let script = PowerShellScript(source: Self.homeDirectoryScript)
        let data = try await channel.run(script, operation: "HomeDirectory")
        let nativePath = try JSONDecoder.detoursWindows.decode(String.self, from: data)
        return try WindowsPath.remotePath(fromNative: nativePath)
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        let windowsPath = try WindowsPath(location: location, hostID: hostID)
        if windowsPath.isSyntheticRoot {
            return try await listDrives()
        }

        guard let nativePath = windowsPath.nativePath else {
            throw WindowsPathError.nativePathRequired(windowsPath.remotePath)
        }
        let arguments = PathArguments(path: nativePath, showHidden: showHidden)
        let script = try PowerShellScript(source: Self.listScript, arguments: arguments)
        let data = try await channel.run(script, operation: "List")
        let entries = try WindowsReplyDecoder.decodeArrayOrSingle(WindowsDirectoryEntry.self, from: data)
        return try entries.map(loadedEntry)
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        let windowsPath = try WindowsPath(location: location, hostID: hostID)
        guard let nativePath = windowsPath.nativePath else {
            throw WindowsPathError.nativePathRequired(windowsPath.remotePath)
        }
        let script = try PowerShellScript(source: Self.statScript, arguments: PathArguments(path: nativePath))
        let data = try await channel.run(script, operation: "Stat")
        let entry = try JSONDecoder.detoursWindows.decode(WindowsDirectoryEntry.self, from: data)
        return try loadedEntry(entry)
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func copyItem(_ source: Location, to target: Location) async throws -> Location {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func moveItem(_ source: Location, to target: Location) async throws -> Location {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func delete(_ items: [Location]) async throws {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        let lifetime = try await channel.acquireLifetime(.watch)
        var retained = false
        defer { if !retained { lifetime?.release() } }
        let generation = try await channel.readyForAuxiliaryRequest()
        let windowsPath = try windowsPath(from: location)
        if windowsPath.isSyntheticRoot {
            return FileProviderWatch(id: UUID(), location: location)
        }
        guard let watchChannel else {
            throw WindowsWatchChannelError.missingChannel
        }
        let watch = try await watchChannel.watch(
            location,
            nativePath: try nativePath(from: windowsPath),
            onChange: onChange
        )
        do {
            try await channel.validateAuxiliaryRequest(generation: generation)
            watchLifetimes[watch] = lifetime
            retained = true
            return watch
        } catch {
            await watchChannel.unwatch(watch)
            throw error
        }
    }

    func unwatch(_ watch: FileProviderWatch) async {
        let lifetime = watchLifetimes.removeValue(forKey: watch)
        defer { lifetime?.release() }
        await watchChannel?.unwatch(watch)
    }

    /// Tears down every watch on this host, killing each remote watcher process. Used on app
    /// quit so watchers do not orphan on the host when the connection is abandoned.
    func stopWatching() async {
        let lifetimes = Array(watchLifetimes.values)
        watchLifetimes.removeAll()
        await watchChannel?.stop()
        for lifetime in lifetimes { await lifetime.releaseAndWait() }
    }

    func invalidateWatchWorkers() async {
        await watchChannel?.invalidateWorkers()
    }

    func reregisterWatchesAfterReconnect() async throws {
        try await watchChannel?.reregisterAfterReconnect()
    }

    func gitStatus(for directory: Location) async -> [Location: GitStatus] {
        guard let windowsPath = try? windowsPath(from: directory),
              let nativePath = windowsPath.nativePath else {
            return [:]
        }
        let script: PowerShellScript
        do {
            script = try PowerShellScript(source: WindowsFindScripts.gitStatus, arguments: PathArguments(path: nativePath))
        } catch {
            return [:]
        }
        guard let data = try? await channel.run(script, operation: "GitStatus"),
              let replies = try? WindowsReplyDecoder.decodeArrayOrSingle(WindowsGitStatusReply.self, from: data) else {
            return [:]
        }
        var statuses: [Location: GitStatus] = [:]
        for reply in replies {
            guard let status = GitStatus(rawValue: reply.status),
                  let location = try? WindowsPath.location(fromNative: reply.nativePath, hostID: hostID) else {
                continue
            }
            statuses[location] = status
        }
        return statuses
    }

    func folderSize(for location: Location) async throws -> Int64 {
        let windowsPath = try WindowsPath(location: location, hostID: hostID)
        guard let nativePath = windowsPath.nativePath else {
            throw WindowsPathError.nativePathRequired(windowsPath.remotePath)
        }
        let script = try PowerShellScript(source: Self.folderSizeScript, arguments: PathArguments(path: nativePath))
        let data = try await channel.run(script, operation: "FolderSize")
        return try JSONDecoder.detoursWindows.decode(Int64.self, from: data)
    }

    /// Windows links and junctions keep their existing transfer path.
    nonisolated var supportsSymbolicLinks: Bool { false }

    func readSymlink(_ location: Location) async throws -> Location {
        let windowsPath = try WindowsPath(location: location, hostID: hostID)
        guard let nativePath = windowsPath.nativePath else {
            throw WindowsPathError.nativePathRequired(windowsPath.remotePath)
        }
        let script = try PowerShellScript(source: Self.readSymlinkScript, arguments: PathArguments(path: nativePath))
        let data = try await channel.run(script, operation: "ReadSymlink")
        let target = try JSONDecoder.detoursWindows.decode(String.self, from: data)
        return try WindowsPath.location(fromNative: target, hostID: hostID)
    }

    func openForQuickLook(_ location: Location) async throws -> URL {
        let entry = try await stat(location)
        guard let size = entry.fileSize else {
            throw FileProviderError.unsupportedOperation("quick look directory")
        }
        guard size <= RemoteFileCache.quickLookMaximumBytes else {
            throw FileProviderError.unsupportedOperation("Remote Quick Look supports files up to 100 MB")
        }
        let remotePath = try windowsPath(from: location)
        let destination = try RemoteFileCache.makeSessionFile(hostID: hostID, remotePath: remotePath.remotePath)
        try await transferChannel.download(
            remotePath: try nativePath(from: remotePath),
            expectedByteCount: size,
            to: destination
        )
        return destination
    }

    func download(_ location: Location, to localURL: URL) async throws {
        let entry = try await stat(location)
        let size = entry.fileSize ?? 0
        let remotePath = try windowsPath(from: location)
        try await transferChannel.download(
            remotePath: try nativePath(from: remotePath),
            expectedByteCount: size,
            to: localURL
        )
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        throw WindowsTransferError.acceptedOperationRequired
    }

    /// Small app-owned control writes use the existing PowerShell channel instead of opening a
    /// second SFTP connection. This is intentionally bounded and is used by the guarded UI-test
    /// fixture seam while the live provider session owns the host connection.
    func writeSmallControlFile(_ data: Data, to location: Location, hidden: Bool) async throws {
        guard data.count <= 64 * 1024 else {
            throw FileProviderError.unsupportedOperation("Control file exceeds 64 KiB")
        }
        let arguments = try WindowsSmallFileWriteArguments(
            path: nativePath(from: windowsPath(from: location)),
            contentsBase64: data.base64EncodedString(),
            hidden: hidden
        )
        let script = try PowerShellScript(source: Self.smallFileWriteScript, arguments: arguments)
        _ = try await channel.run(script, operation: "SmallControlWrite")
    }

    func readSmallControlFile(_ location: Location) async throws -> Data {
        let arguments = try PathArguments(path: nativePath(from: windowsPath(from: location)))
        let script = try PowerShellScript(source: Self.smallFileReadScript, arguments: arguments)
        let response = try await channel.run(script, operation: "SmallControlRead")
        let encoded = try JSONDecoder.detoursWindows.decode(String.self, from: response)
        guard let data = Data(base64Encoded: encoded), data.count <= 64 * 1024 else {
            throw RemoteFileProviderError.invalidResponse("SmallControlRead")
        }
        return data
    }

    func version(of location: Location) async throws -> RemoteFileVersion {
        let windowsPath = try WindowsPath(location: location, hostID: hostID)
        guard let nativePath = windowsPath.nativePath else {
            throw WindowsPathError.nativePathRequired(windowsPath.remotePath)
        }
        let script = try PowerShellScript(source: Self.versionScript, arguments: PathArguments(path: nativePath))
        let data = try await channel.run(script, operation: "Version")
        let reply = try JSONDecoder.detoursWindows.decode(VersionReply.self, from: data)
        return RemoteFileVersion(sha256: reply.sha256, modificationDate: reply.modificationDate)
    }

    nonisolated func find(query: String, cap: Int) -> AsyncThrowingStream<[FoundItem], Error> {
        find(query: query, cap: cap, root: nil)
    }

    nonisolated func find(query: String, cap: Int, root: Location?) -> AsyncThrowingStream<[FoundItem], Error> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = self.hostID
        let channel = self.channel
        // Capture the search root for this call only. It is derived from the directory the
        // search was launched from, never from shared mutable state, so a concurrent listing
        // in another pane cannot redirect this search.
        let root: String? = {
            guard let root, let windowsPath = try? WindowsPath(location: root, hostID: hostID) else { return nil }
            return windowsPath.nativePath
        }()

        return AsyncThrowingStream { continuation in
            guard !trimmed.isEmpty, let root else {
                continuation.finish()
                return
            }
            let task = Task {
                do {
                    let arguments = WindowsFindArguments(root: root, query: trimmed, cap: min(max(cap, 1), 1_000))
                    let script = try PowerShellScript(source: WindowsFindScripts.find, arguments: arguments)
                    let data = try await channel.run(script, operation: "Find")
                    let replies = try WindowsReplyDecoder.decodeArrayOrSingle(WindowsFindReply.self, from: data)
                    let items = replies.compactMap { reply -> FoundItem? in
                        guard let location = try? WindowsPath.location(fromNative: reply.nativePath, hostID: hostID) else {
                            return nil
                        }
                        return FoundItem(location: location, isDirectory: reply.isDirectory)
                    }
                    let chunkSize = 100
                    for start in stride(from: 0, to: items.count, by: chunkSize) {
                        try Task.checkCancellation()
                        continuation.yield(Array(items[start..<min(start + chunkSize, items.count)]))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func listDrives() async throws -> [LoadedFileEntry] {
        let script = PowerShellScript(source: Self.driveListScript)
        let data = try await channel.run(script, operation: "DriveList")
        let drives = try WindowsReplyDecoder.decodeArrayOrSingle(WindowsDriveEntry.self, from: data)
        return try drives.map { drive in
            let remotePath = try WindowsPath.remotePath(fromNative: drive.nativeRoot)
            let location = Location.remote(hostID: hostID, path: remotePath)
            rawPaths[location] = remotePath
            return LoadedFileEntry(
                location: location,
                url: URL(fileURLWithPath: remotePath),
                name: "\(drive.name):",
                isDirectory: true
            )
        }
    }

    private func windowsPath(from location: Location) throws -> WindowsPath {
        try WindowsPath(location: location, hostID: hostID)
    }

    private func nativePath(from path: WindowsPath) throws -> String {
        guard let nativePath = path.nativePath else {
            throw WindowsPathError.nativePathRequired(path.remotePath)
        }
        return nativePath
    }

    private func loadedEntry(_ entry: WindowsDirectoryEntry) throws -> LoadedFileEntry {
        let remotePath = try WindowsPath.remotePath(fromNative: entry.nativePath)
        let location = Location.remote(hostID: hostID, path: remotePath)
        rawPaths[location] = entry.nativePath
        return LoadedFileEntry(
            location: location,
            url: URL(fileURLWithPath: remotePath),
            name: entry.name,
            isDirectory: entry.isDirectory,
            isSymbolicLink: entry.isReparsePoint,
            isHidden: entry.isHidden,
            fileSize: entry.isDirectory ? nil : entry.byteCount,
            contentModificationDate: entry.modificationDate
        )
    }
}

struct PathArguments: Encodable {
    let path: String
    let showHidden: Bool?

    init(path: String, showHidden: Bool? = nil) {
        self.path = path
        self.showHidden = showHidden
    }
}

private struct CreateDirectoryArguments: Encodable {
    let path: String
    let intermediate: Bool
}

private struct RenameArguments: Encodable {
    let path: String
    let newName: String
}

private struct TransferArguments: Encodable {
    let sources: [String]
    let destination: String
}

private struct ItemTransferArguments: Encodable {
    let source: String
    let target: String
}

private struct TrashArguments: Encodable {
    let paths: [String]
}

private struct RestoreTrashArguments: Encodable {
    let items: [RestoreTrashItemArgument]
}

private struct RestoreTrashItemArgument: Encodable {
    let originalPath: String
    let trashToken: String
}

private struct ArchiveCreateArguments: Encodable {
    let items: [String]
    let format: String
    let archiveName: String
    let password: String?
}

private struct ArchiveExtractArguments: Encodable {
    let archive: String
    let format: String
    let password: String?
}

private struct WindowsFindArguments: Encodable {
    let root: String
    let query: String
    let cap: Int
}

private struct WindowsSmallFileWriteArguments: Encodable {
    let path: String
    let contentsBase64: String
    let hidden: Bool
}

private struct WindowsFindReply: Decodable {
    let nativePath: String
    let isDirectory: Bool

    private enum CodingKeys: String, CodingKey {
        case nativePath = "FullName"
        case isDirectory = "PSIsContainer"
    }
}

private struct WindowsGitStatusReply: Decodable {
    let nativePath: String
    let status: String

    private enum CodingKeys: String, CodingKey {
        case nativePath = "FullName"
        case status = "Status"
    }
}

private struct WindowsArchiveToolAvailability: Decodable {
    let sevenZip: Bool
    let tar: Bool

    private enum CodingKeys: String, CodingKey {
        case sevenZip = "SevenZip"
        case tar = "Tar"
    }
}

private struct WindowsTrashReply: Decodable {
    let originalPath: String
    let trashToken: String

    private enum CodingKeys: String, CodingKey {
        case originalPath = "OriginalPath"
        case trashToken = "TrashToken"
    }
}

private enum WindowsTrashLocation {
    static let prefix = "/.detours-trash/"

    static func location(token: String, hostID: UUID) -> Location {
        .remote(hostID: hostID, path: prefix + token)
    }

    static func token(from location: Location, hostID: UUID) throws -> String {
        guard case .remote(let locationHostID, let path) = location, locationHostID == hostID else {
            throw WindowsPathError.expectedRemote(location)
        }
        guard path.hasPrefix(prefix) else {
            throw FileProviderError.unsupportedOperation("Invalid Windows trash token")
        }
        return String(path.dropFirst(prefix.count))
    }
}

private struct VersionReply: Decodable {
    let sha256: String
    let modificationDate: Date

    private enum CodingKeys: String, CodingKey {
        case sha256 = "SHA256"
        case modificationDate = "LastWriteTimeUtc"
    }
}
