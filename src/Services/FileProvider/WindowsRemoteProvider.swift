import Foundation

actor WindowsRemoteProvider: FileProvider {
    let hostID: UUID

    private let channel: PowerShellChannel
    private let transferChannel: WindowsTransferChannel
    private let watchChannel: WindowsWatchChannel?
    private let searchScope = WindowsSearchScope()
    private var rawPaths: [Location: String] = [:]
    private var archiveToolAvailability: WindowsArchiveToolAvailability?

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
        searchScope.setActiveDirectory(nativePath)
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
        searchScope.setActiveDirectory(nativePath)
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
        guard !sources.isEmpty else { return [] }
        let arguments = try TransferArguments(
            sources: sources.map { try nativePath(from: windowsPath(from: $0)) },
            destination: nativePath(from: windowsPath(from: destination))
        )
        let script = try PowerShellScript(source: Self.copyScript, arguments: arguments)
        let data = try await channel.run(script, operation: "Copy")
        return try decodeNativeLocations(from: data)
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        guard !sources.isEmpty else { return [] }
        let arguments = try TransferArguments(
            sources: sources.map { try nativePath(from: windowsPath(from: $0)) },
            destination: nativePath(from: windowsPath(from: destination))
        )
        let script = try PowerShellScript(source: Self.moveScript, arguments: arguments)
        let data = try await channel.run(script, operation: "Move")
        return try decodeNativeLocations(from: data)
    }

    func delete(_ items: [Location]) async throws {
        _ = try await trash(items)
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        guard !items.isEmpty else { return [] }
        let arguments = try TrashArguments(paths: items.map { try nativePath(from: windowsPath(from: $0)) })
        let script = try PowerShellScript(source: Self.trashScript, arguments: arguments)
        let data = try await channel.run(script, operation: "Trash")
        let replies = try WindowsReplyDecoder.decodeArrayOrSingle(WindowsTrashReply.self, from: data)
        return try replies.map { reply in
            TrashedItem(
                originalLocation: try WindowsPath.location(fromNative: reply.originalPath, hostID: hostID),
                trashLocation: WindowsTrashLocation.location(token: reply.trashToken, hostID: hostID)
            )
        }
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        guard !items.isEmpty else { return [] }
        let arguments = try RestoreTrashArguments(items: items.map { item in
            RestoreTrashItemArgument(
                originalPath: try nativePath(from: windowsPath(from: item.originalLocation)),
                trashToken: try WindowsTrashLocation.token(from: item.trashLocation, hostID: hostID)
            )
        })
        let script = try PowerShellScript(source: Self.restoreTrashScript, arguments: arguments)
        let data = try await channel.run(script, operation: "RestoreFromTrash")
        return try decodeNativeLocations(from: data)
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        let arguments = try RenameArguments(path: nativePath(from: windowsPath(from: item)), newName: newName)
        let script = try PowerShellScript(source: Self.renameScript, arguments: arguments)
        let data = try await channel.run(script, operation: "Rename")
        guard let renamed = try decodeNativeLocations(from: data).first else {
            throw RemoteFileProviderError.invalidResponse("rename")
        }
        return renamed
    }

    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        guard !items.isEmpty else {
            throw FileOperationError.archiveProcessFailed("No items selected for archive.")
        }
        let arguments = try ArchiveCreateArguments(
            items: items.map { try nativePath(from: windowsPath(from: $0)) },
            format: format.rawValue,
            archiveName: archiveName,
            password: password
        )
        let usesBuiltInZip = format == .zip && (password?.isEmpty ?? true)
        if !usesBuiltInZip {
            try await requireHostArchiveTool(format: format, password: password)
        }
        let script = try PowerShellScript(
            source: usesBuiltInZip ? WindowsArchiveScripts.zipCreate : WindowsArchiveScripts.externalCreate,
            arguments: arguments
        )
        let data = try await channel.run(script, operation: "ArchiveCreate")
        guard let archive = try decodeNativeLocations(from: data).first else {
            throw RemoteFileProviderError.invalidResponse("archiveCreate")
        }
        return archive
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        guard let format = ArchiveFormat.detect(from: URL(fileURLWithPath: archive.path)) else {
            throw FileOperationError.archiveProcessFailed("Unsupported archive format: \(archive.lastPathComponent)")
        }
        let usesBuiltInZip = format == .zip && (password?.isEmpty ?? true)
        if !usesBuiltInZip {
            try await requireHostArchiveTool(format: format, password: password)
        }
        let arguments = try ArchiveExtractArguments(
            archive: nativePath(from: windowsPath(from: archive)),
            format: format.rawValue,
            password: password
        )
        let script = try PowerShellScript(
            source: usesBuiltInZip ? WindowsArchiveScripts.zipExtract : WindowsArchiveScripts.externalExtract,
            arguments: arguments
        )
        let data = try await channel.run(script, operation: "ArchiveExtract")
        guard let extracted = try decodeNativeLocations(from: data).first else {
            throw RemoteFileProviderError.invalidResponse("archiveExtract")
        }
        return extracted
    }

    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {
        let arguments = try CreateDirectoryArguments(
            path: nativePath(from: windowsPath(from: location)),
            intermediate: withIntermediateDirectories
        )
        let script = try PowerShellScript(source: Self.createDirectoryScript, arguments: arguments)
        _ = try await channel.run(script, operation: "CreateDirectory")
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        guard let watchChannel else {
            throw WindowsWatchChannelError.missingChannel
        }
        let windowsPath = try windowsPath(from: location)
        return try await watchChannel.watch(
            location,
            nativePath: try nativePath(from: windowsPath),
            onChange: onChange
        )
    }

    func unwatch(_ watch: FileProviderWatch) async {
        await watchChannel?.unwatch(watch)
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
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = Int64(values.fileSize ?? 0)
        let remotePath = try windowsPath(from: location)
        try await transferChannel.upload(
            localURL: localURL,
            remotePath: try nativePath(from: remotePath),
            byteCount: byteCount
        )
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = self.hostID
        let channel = self.channel
        let root = searchScope.activeDirectory

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

    private func decodeNativeLocations(from data: Data) throws -> [Location] {
        try WindowsReplyDecoder.decodeArrayOrSingle(String.self, from: data).map { nativePath in
            try WindowsPath.location(fromNative: nativePath, hostID: hostID)
        }
    }

    private func requireHostArchiveTool(format: ArchiveFormat, password: String?) async throws {
        let tools = try await hostArchiveTools()
        switch format {
        case .zip:
            if !(password?.isEmpty ?? true), !tools.sevenZip {
                throw FileOperationError.archiveToolNotFound("7z")
            }
        case .sevenZ:
            guard tools.sevenZip else { throw FileOperationError.archiveToolNotFound("7z") }
        case .tarGz, .tarBz2, .tarXz:
            guard tools.tar else { throw FileOperationError.archiveToolNotFound("tar") }
        }
    }

    private func hostArchiveTools() async throws -> WindowsArchiveToolAvailability {
        if let archiveToolAvailability {
            return archiveToolAvailability
        }
        let script = PowerShellScript(source: WindowsArchiveScripts.toolAvailability)
        let data = try await channel.run(script, operation: "ArchiveTools")
        let tools = try JSONDecoder.detoursWindows.decode(WindowsArchiveToolAvailability.self, from: data)
        archiveToolAvailability = tools
        return tools
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

private final class WindowsSearchScope: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var activeDirectory: String? {
        lock.withLock { storage }
    }

    func setActiveDirectory(_ path: String) {
        lock.withLock {
            storage = path
        }
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

private extension WindowsRemoteProvider {
    static let homeDirectoryScript = PowerShellScript.prelude(
        operationBody: """
        [Environment]::GetFolderPath('UserProfile')
        """
    )

    static let driveListScript = PowerShellScript.prelude(
        operationBody: """
        Get-PSDrive -PSProvider FileSystem | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Root = $_.Root
                Free = if ($null -eq $_.Free) { $null } else { [int64]$_.Free }
                Used = if ($null -eq $_.Used) { $null } else { [int64]$_.Used }
            }
        }
        """
    )

    static let listScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        function Convert-Item($Item) {
            [pscustomobject]@{
                Name = $Item.Name
                FullName = $Item.FullName
                PSIsContainer = [bool]$Item.PSIsContainer
                Attributes = $Item.Attributes.ToString()
                Length = if ($Item.PSIsContainer) { $null } else { [int64]$Item.Length }
                LastWriteTimeUtc = [int64]([DateTimeOffset]$Item.LastWriteTimeUtc).ToUnixTimeMilliseconds()
            }
        }

        Get-ChildItem -LiteralPath $Arguments.path -Force | Where-Object {
            [bool]$Arguments.showHidden -or -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)
        } | ForEach-Object { Convert-Item $_ }
        """
    )

    static let statScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        [pscustomobject]@{
            Name = $item.Name
            FullName = $item.FullName
            PSIsContainer = [bool]$item.PSIsContainer
            Attributes = $item.Attributes.ToString()
            Length = if ($item.PSIsContainer) { $null } else { [int64]$item.Length }
            LastWriteTimeUtc = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        }
        """
    )

    static let createDirectoryScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        if ($Arguments.intermediate) {
            [System.IO.Directory]::CreateDirectory($Arguments.path) | Out-Null
        } else {
            New-Item -ItemType Directory -Path $Arguments.path -ErrorAction Stop | Out-Null
        }
        $Arguments.path
        """
    )

    static let renameScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        $parent = [System.IO.Path]::GetDirectoryName($item.FullName)
        $destination = Join-Path -Path $parent -ChildPath $Arguments.newName
        Rename-Item -LiteralPath $item.FullName -NewName $Arguments.newName -ErrorAction Stop
        (Get-Item -LiteralPath $destination -Force).FullName
        """
    )

    static let copyScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        \(recycleBinHelpers)

        foreach ($source in $Arguments.sources) {
            $sourceItem = Get-Item -LiteralPath $source -Force
            $target = Join-Path -Path $Arguments.destination -ChildPath $sourceItem.Name
            if ([string]::Equals($sourceItem.FullName, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Cannot copy an item onto itself: $($sourceItem.FullName)"
            }
            if (Test-Path -LiteralPath $target) {
                Send-ToRecycleBin -Path $target
            }
            Copy-Item -LiteralPath $sourceItem.FullName -Destination $target -Recurse -Force -ErrorAction Stop
            (Get-Item -LiteralPath $target -Force).FullName
        }
        """
    )

    static let moveScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        \(recycleBinHelpers)

        foreach ($source in $Arguments.sources) {
            $sourceItem = Get-Item -LiteralPath $source -Force
            $target = Join-Path -Path $Arguments.destination -ChildPath $sourceItem.Name
            if ([string]::Equals($sourceItem.FullName, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Cannot move an item onto itself: $($sourceItem.FullName)"
            }
            if (Test-Path -LiteralPath $target) {
                Send-ToRecycleBin -Path $target
            }
            Move-Item -LiteralPath $sourceItem.FullName -Destination $target -Force -ErrorAction Stop
            (Get-Item -LiteralPath $target -Force).FullName
        }
        """
    )

    static let trashScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        \(recycleBinHelpers)

        foreach ($path in $Arguments.paths) {
            $item = Get-Item -LiteralPath $path -Force
            $originalPath = $item.FullName
            $trashPath = Send-ToRecycleBin -Path $originalPath
            $token = ConvertTo-Base64UrlJson @{
                OriginalPath = $originalPath
                TrashPath = $trashPath
            }
            [pscustomobject]@{
                OriginalPath = $originalPath
                TrashToken = $token
            }
        }
        """
    )

    static let restoreTrashScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        \(recycleBinHelpers)

        foreach ($entry in $Arguments.items) {
            $token = ConvertFrom-Base64UrlJson -Token $entry.trashToken
            if (Test-Path -LiteralPath $entry.originalPath) {
                throw "Restore destination already exists: $($entry.originalPath)"
            }
            $trashPath = [string]$token.TrashPath
            if ([string]::IsNullOrWhiteSpace($trashPath) -or -not (Test-Path -LiteralPath $trashPath)) {
                throw "Could not find matching trash item for: $($entry.originalPath)"
            }

            $parent = [System.IO.Path]::GetDirectoryName([string]$entry.originalPath)
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                [System.IO.Directory]::CreateDirectory($parent) | Out-Null
            }
            Move-Item -LiteralPath $trashPath -Destination $entry.originalPath -Force -ErrorAction Stop
            $entry.originalPath
        }
        """
    )

    static let folderSizeScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        if (-not $item.PSIsContainer) { [int64]$item.Length; return }
        $sum = (Get-ChildItem -LiteralPath $Arguments.path -Force -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { [int64]0 } else { [int64]$sum }
        """
    )

    static let readSymlinkScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        if ($item.Target) {
            if ($item.Target -is [array]) { $item.Target[0] } else { $item.Target }
        } else {
            $item.FullName
        }
        """
    )

    static let versionScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        $hash = if ($item.PSIsContainer) { '' } else { (Get-FileHash -LiteralPath $Arguments.path -Algorithm SHA256).Hash.ToLowerInvariant() }
        [pscustomobject]@{
            SHA256 = $hash
            LastWriteTimeUtc = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        }
        """
    )

    static let recycleBinHelpers = """
    function Get-DetoursTrashRoot {
        $profile = [Environment]::GetFolderPath('UserProfile')
        if ([string]::IsNullOrWhiteSpace($profile)) { throw "Windows user profile is unavailable." }
        $root = Join-Path -Path $profile -ChildPath '.detours-trash'
        [System.IO.Directory]::CreateDirectory($root) | Out-Null
        $root
    }

    function New-DetoursTrashPath([string]$Name) {
        $root = Get-DetoursTrashRoot
        while ($true) {
            $candidate = Join-Path -Path $root -ChildPath "$([guid]::NewGuid().ToString())-$Name"
            if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        }
    }

    function Send-ToRecycleBin([string]$Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $trashPath = New-DetoursTrashPath -Name $item.Name
        Move-Item -LiteralPath $item.FullName -Destination $trashPath -Force -ErrorAction Stop
        $trashPath
    }

    function ConvertTo-Base64UrlJson($Value) {
        $json = $Value | ConvertTo-Json -Compress -Depth 6
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json)).
            TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }

    function ConvertFrom-Base64UrlJson([string]$Token) {
        $base64 = $Token.Replace('-', '+').Replace('_', '/')
        switch ($base64.Length % 4) {
            0 { break }
            2 { $base64 += '==' }
            3 { $base64 += '=' }
            default { throw "Invalid Windows trash token." }
        }
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64)) | ConvertFrom-Json
    }
    """
}
