import Foundation

enum ServerArchiveFormat: String, Equatable, Sendable {
    case zip
    case sevenZ
    case tarGz
    case tarBz2
    case tarXz

    var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .sevenZ: "7z"
        case .tarGz: "tar.gz"
        case .tarBz2: "tar.bz2"
        case .tarXz: "tar.xz"
        }
    }

    var requiredTools: [String] {
        switch self {
        case .zip: ["zip"]
        case .sevenZ: ["7z"]
        case .tarGz, .tarBz2: ["tar"]
        case .tarXz: ["tar", "xz"]
        }
    }

    var extractionTools: [String] {
        switch self {
        case .zip: ["unzip"]
        case .sevenZ: ["7z"]
        case .tarGz, .tarBz2: ["tar"]
        case .tarXz: ["tar", "xz"]
        }
    }

    static func detect(path: String) -> ServerArchiveFormat? {
        let lowercased = path.lowercased()
        if lowercased.hasSuffix(".tar.gz") || lowercased.hasSuffix(".tgz") { return .tarGz }
        if lowercased.hasSuffix(".tar.bz2") || lowercased.hasSuffix(".tbz2") { return .tarBz2 }
        if lowercased.hasSuffix(".tar.xz") || lowercased.hasSuffix(".txz") { return .tarXz }
        if lowercased.hasSuffix(".zip") { return .zip }
        if lowercased.hasSuffix(".7z") { return .sevenZ }
        return nil
    }
}

enum ArchiveOperationPhase: String, Equatable, Sendable {
    case starting
    case running
    case completed
}

struct ArchiveProgressFrame: Equatable, Sendable {
    let phase: ArchiveOperationPhase
    let path: String
    let completedItems: Int
    let totalItems: Int
}

struct ServerProcessResult: Equatable, Sendable {
    let status: Int32
    let stderr: String
}

enum ArchiveOperationsError: Error, Equatable, Sendable {
    case noItems
    case invalidArchiveName(String)
    case unsupportedFormat(String)
    case missingTool(String)
    case processFailed(String)
    case emptyArchive(String)
    case passwordUnsupported
}

struct ArchiveOperations {
    typealias ToolResolver = @Sendable (String) -> String?
    typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ currentDirectory: URL?) throws -> ServerProcessResult

    private let fileManager: FileManager
    private let resolveTool: ToolResolver
    private let runProcess: ProcessRunner

    init(
        fileManager: FileManager = .default,
        resolveTool: @escaping ToolResolver = ArchiveOperations.resolveToolOnPath,
        runProcess: @escaping ProcessRunner = ArchiveOperations.runProcess
    ) {
        self.fileManager = fileManager
        self.resolveTool = resolveTool
        self.runProcess = runProcess
    }

    func createArchive(
        items: [String],
        format rawFormat: String,
        archiveName: String,
        password: String?,
        progress: (ArchiveProgressFrame) -> Void = { _ in }
    ) throws -> String {
        guard !items.isEmpty else { throw ArchiveOperationsError.noItems }
        if let password, !password.isEmpty {
            throw ArchiveOperationsError.passwordUnsupported
        }
        let format = try archiveFormat(rawFormat)
        try validateArchiveName(archiveName)
        let tools = try resolvedTools(format.requiredTools)

        let itemURLs = items.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let parentDirectory = itemURLs[0].deletingLastPathComponent()
        let archiveURL = uniqueDestination(
            in: parentDirectory,
            baseName: archiveName,
            extension: format.fileExtension
        )

        progress(ArchiveProgressFrame(phase: .starting, path: archiveURL.path, completedItems: 0, totalItems: items.count))

        let command = createCommand(
            format: format,
            tools: tools,
            items: itemURLs,
            destination: archiveURL,
            password: password
        )

        let result = try runProcess(command.executable, command.arguments, command.currentDirectory)
        if result.status != 0 {
            try? fileManager.removeItem(at: archiveURL)
            throw ArchiveOperationsError.processFailed(Self.errorMessage(result.stderr, fallback: command.executable))
        }

        progress(ArchiveProgressFrame(phase: .completed, path: archiveURL.path, completedItems: items.count, totalItems: items.count))
        return archiveURL.path
    }

    func extractArchive(
        archive path: String,
        password: String?,
        progress: (ArchiveProgressFrame) -> Void = { _ in }
    ) throws -> String {
        if let password, !password.isEmpty {
            throw ArchiveOperationsError.passwordUnsupported
        }
        let archiveURL = URL(fileURLWithPath: path).standardizedFileURL
        guard let format = ServerArchiveFormat.detect(path: archiveURL.path) else {
            throw ArchiveOperationsError.unsupportedFormat(archiveURL.lastPathComponent)
        }
        let tools = try resolvedTools(format.extractionTools)
        let parentDirectory = archiveURL.deletingLastPathComponent()
        let tempDirectory = parentDirectory.appendingPathComponent(".detours-extract-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        progress(ArchiveProgressFrame(phase: .starting, path: archiveURL.path, completedItems: 0, totalItems: 1))

        do {
            let command = extractCommand(
                format: format,
                tools: tools,
                archive: archiveURL,
                destination: tempDirectory,
                password: password
            )
            let result = try runProcess(command.executable, command.arguments, command.currentDirectory)
            guard result.status == 0 else {
                throw ArchiveOperationsError.processFailed(Self.errorMessage(result.stderr, fallback: command.executable))
            }

            let extracted = try materialiseExtractionResult(
                tempDirectory: tempDirectory,
                archive: archiveURL,
                format: format
            )
            progress(ArchiveProgressFrame(phase: .completed, path: extracted.path, completedItems: 1, totalItems: 1))
            return extracted.path
        } catch {
            try? fileManager.removeItem(at: tempDirectory)
            throw error
        }
    }

    private func archiveFormat(_ rawFormat: String) throws -> ServerArchiveFormat {
        guard let format = ServerArchiveFormat(rawValue: rawFormat) else {
            throw ArchiveOperationsError.unsupportedFormat(rawFormat)
        }
        return format
    }

    private func validateArchiveName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("/") || trimmed.contains(":") || trimmed.contains("\0") {
            throw ArchiveOperationsError.invalidArchiveName(name)
        }
    }

    private func resolvedTools(_ tools: [String]) throws -> [String: String] {
        var resolved: [String: String] = [:]
        for tool in tools {
            guard let path = resolveTool(tool) else {
                throw ArchiveOperationsError.missingTool(tool)
            }
            resolved[tool] = path
        }
        return resolved
    }

    private func createCommand(
        format: ServerArchiveFormat,
        tools: [String: String],
        items: [URL],
        destination: URL,
        password: String?
    ) -> (executable: String, arguments: [String], currentDirectory: URL?) {
        switch format {
        case .zip:
            var arguments = ["-r", "-q"]
            if let password, !password.isEmpty {
                return (tools["zip"]!, ["--passwords-disabled"], nil)
            }
            arguments.append(destination.path)
            arguments.append(contentsOf: items.map(\.lastPathComponent))
            return (tools["zip"]!, arguments, items[0].deletingLastPathComponent())
        case .sevenZ:
            var arguments = ["a", "-t7z"]
            if let password, !password.isEmpty {
                return (tools["7z"]!, ["--passwords-disabled"], nil)
            }
            arguments.append(destination.path)
            arguments.append(contentsOf: items.map(\.path))
            return (tools["7z"]!, arguments, nil)
        case .tarGz:
            return tarCreateCommand(tool: tools["tar"]!, flag: "z", items: items, destination: destination)
        case .tarBz2:
            return tarCreateCommand(tool: tools["tar"]!, flag: "j", items: items, destination: destination)
        case .tarXz:
            return tarCreateCommand(tool: tools["tar"]!, flag: "J", items: items, destination: destination)
        }
    }

    private func tarCreateCommand(
        tool: String,
        flag: String,
        items: [URL],
        destination: URL
    ) -> (executable: String, arguments: [String], currentDirectory: URL?) {
        var arguments = ["-c\(flag)f", destination.path, "--"]
        arguments.append(contentsOf: items.map(\.lastPathComponent))
        return (tool, arguments, items[0].deletingLastPathComponent())
    }

    private func extractCommand(
        format: ServerArchiveFormat,
        tools: [String: String],
        archive: URL,
        destination: URL,
        password: String?
    ) -> (executable: String, arguments: [String], currentDirectory: URL?) {
        switch format {
        case .zip:
            var arguments = ["-q"]
            if let password, !password.isEmpty {
                return (tools["unzip"]!, ["--passwords-disabled"], nil)
            }
            arguments.append(contentsOf: [archive.path, "-d", destination.path])
            return (tools["unzip"]!, arguments, nil)
        case .sevenZ:
            var arguments = ["x", "-y", "-o\(destination.path)"]
            if let password, !password.isEmpty {
                return (tools["7z"]!, ["--passwords-disabled"], nil)
            }
            arguments.append(archive.path)
            return (tools["7z"]!, arguments, nil)
        case .tarGz:
            return (tools["tar"]!, ["-xzf", archive.path, "-C", destination.path], nil)
        case .tarBz2:
            return (tools["tar"]!, ["-xjf", archive.path, "-C", destination.path], nil)
        case .tarXz:
            return (tools["tar"]!, ["-xJf", archive.path, "-C", destination.path], nil)
        }
    }

    private func materialiseExtractionResult(
        tempDirectory: URL,
        archive: URL,
        format: ServerArchiveFormat
    ) throws -> URL {
        let items = try fileManager.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        guard !items.isEmpty else {
            throw ArchiveOperationsError.emptyArchive(archive.path)
        }

        let parentDirectory = archive.deletingLastPathComponent()
        if items.count == 1, let item = items.first {
            let destination = uniqueDestination(in: parentDirectory, baseName: item.lastPathComponent, extension: nil)
            try fileManager.moveItem(at: item, to: destination)
            try? fileManager.removeItem(at: tempDirectory)
            return destination
        }

        let wrapper = uniqueDestination(
            in: parentDirectory,
            baseName: archiveBaseName(for: archive, format: format),
            extension: nil
        )
        try fileManager.createDirectory(at: wrapper, withIntermediateDirectories: true)
        for item in items {
            try fileManager.moveItem(at: item, to: wrapper.appendingPathComponent(item.lastPathComponent))
        }
        try? fileManager.removeItem(at: tempDirectory)
        return wrapper
    }

    private func uniqueDestination(in directory: URL, baseName: String, extension ext: String?) -> URL {
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "" : " \(attempt)"
            let filename = ext.map { "\(baseName)\(suffix).\($0)" } ?? "\(baseName)\(suffix)"
            let candidate = directory.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private func archiveBaseName(for archive: URL, format: ServerArchiveFormat) -> String {
        let name = archive.lastPathComponent
        let lowercased = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz", ".zip", ".7z"] where lowercased.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return archive.deletingPathExtension().lastPathComponent
    }

    private static func errorMessage(_ stderr: String, fallback: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(fallback) failed" : trimmed
    }

    private static func resolveToolOnPath(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL?
    ) throws -> ServerProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return ServerProcessResult(status: process.terminationStatus, stderr: stderr)
    }
}
