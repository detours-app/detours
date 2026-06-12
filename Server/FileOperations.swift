import Foundation

struct FileOperations {
    private let trashOperations: TrashOperations
    private let archiveOperations: ArchiveOperations

    init(
        trashOperations: TrashOperations = TrashOperations(),
        archiveOperations: ArchiveOperations = ArchiveOperations()
    ) {
        self.trashOperations = trashOperations
        self.archiveOperations = archiveOperations
    }

    func list(path: ServerRemotePath, showHidden: Bool) throws -> Data {
        let directory = path.string
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { showHidden || !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let entries = try contents.map { name in
            try fileEntry(path: URL(fileURLWithPath: directory).appendingPathComponent(name).path)
        }
        return encodeFileEntries(entries)
    }

    func stat(path: ServerRemotePath) throws -> Data {
        try encodeFileEntries([fileEntry(path: path.string)])
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sb", path.string]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let size = output.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) } ?? 0
        var writer = ServerRPCBinaryWriter()
        writer.writeInt64(size)
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

    func trash(paths: [String]) throws -> [String] {
        try trashOperations.trash(paths: paths)
    }

    func restoreFromTrash(trashInfoPaths: [String]) throws -> [String] {
        try trashOperations.restore(trashInfoPaths: trashInfoPaths)
    }

    func archiveCreate(items: [String], format: String, archiveName: String, password: String?) throws -> String {
        try archiveOperations.createArchive(
            items: items,
            format: format,
            archiveName: archiveName,
            password: password
        )
    }

    func archiveExtract(archive: String, password: String?) throws -> String {
        try archiveOperations.extractArchive(archive: archive, password: password)
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

    private func sha256Hex(path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.arguments = [path]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ServerRPCError.unsupportedCommand("sha256sum")
        }
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(output.split(whereSeparator: \.isWhitespace).first ?? "")
    }
}
