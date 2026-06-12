import Foundation

struct FileOperations {
    static let defaultListChunkSize = 1_000

    private let fileManager: FileManager
    private let trashOperations: TrashOperations
    private let archiveOperations: ArchiveOperations
    private let listChunkSize: Int

    init(
        fileManager: FileManager = .default,
        trashOperations: TrashOperations = TrashOperations(),
        archiveOperations: ArchiveOperations = ArchiveOperations(),
        listChunkSize: Int = Self.defaultListChunkSize
    ) {
        self.fileManager = fileManager
        self.trashOperations = trashOperations
        self.archiveOperations = archiveOperations
        self.listChunkSize = max(1, listChunkSize)
    }

    func list(path: ServerRemotePath, showHidden: Bool) throws -> Data {
        try encodeFileEntries(listEntries(path: path, showHidden: showHidden))
    }

    func listChunks(path: ServerRemotePath, showHidden: Bool) throws -> [Data] {
        let entries = try listEntries(path: path, showHidden: showHidden)
        guard !entries.isEmpty else { return [encodeFileEntries([])] }

        return stride(from: 0, to: entries.count, by: listChunkSize).map { start in
            let end = min(start + listChunkSize, entries.count)
            return encodeFileEntries(Array(entries[start..<end]))
        }
    }

    private func listEntries(path: ServerRemotePath, showHidden: Bool) throws -> [ServerFileEntry] {
        let directory = path.string
        let contents = try fileManager.contentsOfDirectory(atPath: directory)
            .filter { showHidden || !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return try contents.map { name in
            try fileEntry(path: URL(fileURLWithPath: directory).appendingPathComponent(name).path)
        }
    }

    func stat(path: ServerRemotePath) throws -> Data {
        try encodeFileEntries([fileEntry(path: path.string)])
    }

    func copy(sources: [ServerRemotePath], destination: ServerRemotePath, maximumRPCBytes: Int64) throws -> Data {
        let destinationURL = URL(fileURLWithPath: destination.string)
        let copied = try sources.map { source in
            let sourceURL = URL(fileURLWithPath: source.string)
            if try byteCount(at: sourceURL) > maximumRPCBytes {
                throw ServerRPCError.unsupportedCommand("copy over rpc threshold")
            }
            let finalURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            try? fileManager.removeItem(at: finalURL)
            try fileManager.copyItem(at: sourceURL, to: finalURL)
            return ServerRemotePath(finalURL.path)
        }
        return encodePathList(copied)
    }

    func move(sources: [ServerRemotePath], destination: ServerRemotePath) throws -> Data {
        let destinationURL = URL(fileURLWithPath: destination.string)
        let moved = try sources.map { source in
            let sourceURL = URL(fileURLWithPath: source.string)
            let finalURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            try? fileManager.removeItem(at: finalURL)
            try fileManager.moveItem(at: sourceURL, to: finalURL)
            return ServerRemotePath(finalURL.path)
        }
        return encodePathList(moved)
    }

    func rename(item: ServerRemotePath, newName: Data) throws -> Data {
        let sourceURL = URL(fileURLWithPath: item.string)
        guard let name = String(bytes: newName, encoding: .utf8) else {
            throw ServerRPCProtocolError.invalidFrame
        }
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(name)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return encodePathList([ServerRemotePath(destinationURL.path)])
    }

    func trash(items: [ServerRemotePath]) throws -> Data {
        let infoPaths = try trashOperations.trash(paths: items.map(\.string)).map(ServerRemotePath.init)
        return encodePathList(infoPaths)
    }

    func restoreFromTrash(items: [ServerRemotePath]) throws -> Data {
        let restored = try trashOperations.restore(trashInfoPaths: items.map(\.string)).map(ServerRemotePath.init)
        return encodePathList(restored)
    }

    func mkDir(path: ServerRemotePath) throws -> Data {
        let url = URL(fileURLWithPath: path.string)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return encodePathList([path])
    }

    func download(path: ServerRemotePath, maximumRPCBytes: Int64) throws -> Data {
        let url = URL(fileURLWithPath: path.string)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard size <= maximumRPCBytes else {
            throw ServerRPCError.unsupportedCommand("download over rpc threshold")
        }
        return try Data(contentsOf: url)
    }

    func upload(path: ServerRemotePath, contents: Data, expectedByteCount: Int64, maximumRPCBytes: Int64) throws {
        guard Int64(contents.count) == expectedByteCount,
              expectedByteCount <= maximumRPCBytes else {
            throw ServerRPCError.unsupportedCommand("upload size mismatch")
        }

        let destination = URL(fileURLWithPath: path.string)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".detours-partial")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: destination)
        try contents.write(to: partial, options: .atomic)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    func fileVersion(path: ServerRemotePath) throws -> Data {
        let url = URL(fileURLWithPath: path.string)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        var writer = ServerRPCBinaryWriter()
        writer.writeString(try sha256Hex(path: path.string))
        writer.writeInt64(Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000))
        return writer.data
    }

    func readSymlink(path: ServerRemotePath) throws -> Data {
        let source = URL(fileURLWithPath: path.string)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        let resolved: String
        if destination.hasPrefix("/") {
            resolved = destination
        } else {
            resolved = source.deletingLastPathComponent().appendingPathComponent(destination).path
        }
        return encodePathList([ServerRemotePath(resolved)])
    }

    func folderSize(path: ServerRemotePath) throws -> Data {
        var writer = ServerRPCBinaryWriter()
        writer.writeInt64(try Self.calculateFolderSize(at: path.string))
        return writer.data
    }

    func gitStatus(directory: ServerRemotePath) throws -> Data {
        let statuses = try GitOperations().status(in: directory.string)
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt32(UInt32(statuses.count))
        for status in statuses {
            writer.writeData(Data(status.path.utf8))
            writer.writeString(status.status.rawValue)
        }
        return writer.data
    }

    func archiveCreate(items: [ServerRemotePath], format: String, archiveName: Data, password: String?) throws -> Data {
        guard let archiveNameString = String(bytes: archiveName, encoding: .utf8) else {
            throw ServerRPCProtocolError.invalidFrame
        }
        let archivePath = try archiveOperations.createArchive(
            items: items.map(\.string),
            format: format,
            archiveName: archiveNameString,
            password: password
        )
        return encodePathList([ServerRemotePath(archivePath)])
    }

    func archiveExtract(archive: ServerRemotePath, password: String?) throws -> Data {
        let extracted = try archiveOperations.extractArchive(archive: archive.string, password: password)
        return encodePathList([ServerRemotePath(extracted)])
    }

    private struct ServerFileEntry {
        let path: ServerRemotePath
        let name: Data
        let isDirectory: Bool
        let isPackage: Bool
        let isAliasFile: Bool
        let isSymbolicLink: Bool
        let isReadable: Bool
        let isHidden: Bool
        let fileSize: Int64?
        let contentModificationDate: Date
    }

    private func fileEntry(path: String) throws -> ServerFileEntry {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let isSymbolicLink = values.isSymbolicLink ?? false
        let fileSize: Int64?
        if isSymbolicLink,
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            fileSize = Int64(Data(target.utf8).count)
        } else if values.isDirectory == true {
            fileSize = nil
        } else {
            fileSize = values.fileSize.map(Int64.init)
        }

        return ServerFileEntry(
            path: ServerRemotePath(path),
            name: Data(url.lastPathComponent.utf8),
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            isAliasFile: values.isAliasFile ?? false,
            isSymbolicLink: isSymbolicLink,
            isReadable: FileManager.default.isReadableFile(atPath: path),
            isHidden: url.lastPathComponent.hasPrefix("."),
            fileSize: fileSize,
            contentModificationDate: values.contentModificationDate ?? Date()
        )
    }

    private func encodeFileEntries(_ entries: [ServerFileEntry]) -> Data {
        var writer = ServerRPCBinaryWriter()
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

    private func encodePathList(_ paths: [ServerRemotePath]) -> Data {
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt32(UInt32(paths.count))
        for path in paths {
            writer.writeData(path.bytes)
        }
        return writer.data
    }

    private func byteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else {
            throw ServerRPCError.unsupportedCommand("copy directory over rpc")
        }
        return Int64(values.fileSize ?? 0)
    }

    private func sha256Hex(path: String) throws -> String {
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.arguments = [path]
        #endif
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ServerRPCError.unsupportedCommand("sha256")
        }
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(output.split(whereSeparator: \.isWhitespace).first ?? "")
    }

    static func calculateFolderSize(at path: String) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        #if os(macOS)
        process.arguments = ["-sk", path]
        #else
        process.arguments = ["-sb", path]
        #endif
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return 0 }
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let value = output.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) } ?? 0
        #if os(macOS)
        return value * 1_024
        #else
        return value
        #endif
    }
}
