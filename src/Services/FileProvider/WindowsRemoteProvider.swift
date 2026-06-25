import Foundation

actor WindowsRemoteProvider: FileProvider {
    let hostID: UUID

    private let channel: PowerShellChannel
    private let transferChannel: WindowsTransferChannel
    private var rawPaths: [Location: String] = [:]

    init(hostID: UUID, channel: PowerShellChannel, transferChannel: WindowsTransferChannel) {
        self.hostID = hostID
        self.channel = channel
        self.transferChannel = transferChannel
    }

    init(hostID: UUID, sshTarget: String, channel: PowerShellChannel) {
        self.hostID = hostID
        self.channel = channel
        self.transferChannel = WindowsTransferChannel(sshTarget: sshTarget, powerShellChannel: channel)
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
        throw FileProviderError.unsupportedOperation("Windows copy")
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("Windows move")
    }

    func delete(_ items: [Location]) async throws {
        throw FileProviderError.unsupportedOperation("Windows delete")
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        throw FileProviderError.unsupportedOperation("Windows trash")
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("Windows restore")
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        throw FileProviderError.unsupportedOperation("Windows rename")
    }

    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        throw FileProviderError.unsupportedOperation("Windows archiveCreate")
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        throw FileProviderError.unsupportedOperation("Windows archiveExtract")
    }

    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {
        throw FileProviderError.unsupportedOperation("Windows createDirectory")
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        throw FileProviderError.unsupportedOperation("Windows watch")
    }

    func unwatch(_ watch: FileProviderWatch) async {}

    func gitStatus(for directory: Location) async -> [Location: GitStatus] {
        [:]
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
        AsyncThrowingStream { $0.finish() }
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
        Get-ChildItem -LiteralPath $Arguments.path -Force | Where-Object {
            [bool]$Arguments.showHidden -or -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)
        } | ForEach-Object { Convert-Item $_ }

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
}
