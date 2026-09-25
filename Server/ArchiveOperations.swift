import DetoursProcess
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

    /// Tools needed to create this format.
    ///
    /// A password changes which tool a zip needs. Info-ZIP can only encrypt
    /// with ZipCrypto, which is broken and trivially recoverable, so a
    /// password-protected zip is written by 7-Zip with AES-256 instead. Without
    /// a password the ordinary zip tool is fine.
    func requiredTools(encrypted: Bool) -> [String] {
        switch self {
        case .zip: encrypted ? ["7z"] : ["zip"]
        case .sevenZ: ["7z"]
        case .tarGz, .tarBz2: ["tar"]
        case .tarXz: ["tar", "xz"]
        }
    }

    /// Tools needed to extract. An encrypted zip is AES-256, which Info-ZIP's
    /// unzip cannot read, so it goes back through 7-Zip.
    func extractionTools(encrypted: Bool) -> [String] {
        switch self {
        case .zip: encrypted ? ["7z"] : ["unzip"]
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

struct ServerListingResult: Equatable, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ArchiveOperationsError: Error, Equatable, Sendable {
    case noItems
    case invalidArchiveName(String)
    case unsupportedFormat(String)
    case missingTool(String)
    case processFailed(String)
    case emptyArchive(String)
    case invalidPassword(String)
    case wrongPassword
}

struct ArchiveOperations {
    typealias ToolResolver = @Sendable (String) -> String?
    typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ currentDirectory: URL?) throws -> ServerProcessResult
    typealias ListingRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> ServerListingResult
    typealias PtyRunner = @Sendable (PtyProcessInvocation) throws -> PtyProcessResult

    private let fileManager: FileManager
    private let resolveTool: ToolResolver
    private let runProcess: ProcessRunner
    private let runListingProcess: ListingRunner
    private let runPtyProcess: PtyRunner

    init(
        fileManager: FileManager = .default,
        resolveTool: @escaping ToolResolver = ArchiveOperations.resolveToolOnPath,
        runProcess: @escaping ProcessRunner = ArchiveOperations.runProcess,
        runListingProcess: @escaping ListingRunner = ArchiveOperations.runListingProcess,
        runPtyProcess: @escaping PtyRunner = { try PtyProcessRunner().run($0) }
    ) {
        self.fileManager = fileManager
        self.resolveTool = resolveTool
        self.runProcess = runProcess
        self.runListingProcess = runListingProcess
        self.runPtyProcess = runPtyProcess
    }

    func createArchive(
        items: [String],
        format rawFormat: String,
        archiveName: String,
        password: String?,
        progress: (ArchiveProgressFrame) -> Void = { _ in }
    ) throws -> String {
        guard !items.isEmpty else { throw ArchiveOperationsError.noItems }
        let format = try archiveFormat(rawFormat)
        try validatePassword(password, format: format)
        try validateArchiveName(archiveName)
        let isEncrypted = !(password ?? "").isEmpty
        let tools = try resolvedTools(format.requiredTools(encrypted: isEncrypted))

        let itemURLs = items.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let parentDirectory = itemURLs[0].deletingLastPathComponent()
        let archiveURL = uniqueDestination(
            in: parentDirectory,
            baseName: archiveName,
            extension: format.fileExtension
        )

        progress(ArchiveProgressFrame(phase: .starting, path: archiveURL.path, completedItems: 0, totalItems: items.count))

        let result: ServerProcessResult
        if let password, !password.isEmpty {
            let invocation = try encryptedCreateInvocation(
                format: format,
                tools: tools,
                items: itemURLs,
                destination: archiveURL,
                password: password
            )
            result = Self.serverResult(try runPtyProcess(invocation))
        } else {
            let command = createCommand(
                format: format,
                tools: tools,
                items: itemURLs,
                destination: archiveURL
            )
            result = try runProcess(command.executable, command.arguments, command.currentDirectory)
        }
        if result.status != 0 {
            try? fileManager.removeItem(at: archiveURL)
            throw ArchiveOperationsError.processFailed(Self.errorMessage(result.stderr, fallback: format.fileExtension))
        }

        progress(ArchiveProgressFrame(phase: .completed, path: archiveURL.path, completedItems: items.count, totalItems: items.count))
        return archiveURL.path
    }

    func extractArchive(
        archive path: String,
        password: String?,
        progress: (ArchiveProgressFrame) -> Void = { _ in }
    ) throws -> String {
        let archiveURL = URL(fileURLWithPath: path).standardizedFileURL
        guard let format = ServerArchiveFormat.detect(path: archiveURL.path) else {
            throw ArchiveOperationsError.unsupportedFormat(archiveURL.lastPathComponent)
        }
        try validatePassword(password, format: format)
        let isEncrypted = !(password ?? "").isEmpty
        let tools = try resolvedTools(format.extractionTools(encrypted: isEncrypted))
        let parentDirectory = archiveURL.deletingLastPathComponent()
        let tempDirectory = parentDirectory.appendingPathComponent(".detours-extract-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        progress(ArchiveProgressFrame(phase: .starting, path: archiveURL.path, completedItems: 0, totalItems: 1))

        do {
            try validateArchiveMembers(format: format, tools: tools, archive: archiveURL, password: password)

            let result: ServerProcessResult
            if let password, !password.isEmpty {
                let invocation = try encryptedExtractInvocation(
                    format: format,
                    tools: tools,
                    archive: archiveURL,
                    destination: tempDirectory,
                    password: password
                )
                result = Self.serverResult(try runPtyProcess(invocation))
            } else {
                let command = extractCommand(
                    format: format,
                    tools: tools,
                    archive: archiveURL,
                    destination: tempDirectory
                )
                result = try runProcess(command.executable, command.arguments, command.currentDirectory)
            }
            guard result.status == 0 else {
                if password?.isEmpty == false,
                   Self.isWrongPasswordFailure(format: format, result: result) {
                    throw ArchiveOperationsError.wrongPassword
                }
                throw ArchiveOperationsError.processFailed(Self.errorMessage(result.stderr, fallback: format.fileExtension))
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

    private func validatePassword(_ password: String?, format: ServerArchiveFormat) throws {
        guard let password, !password.isEmpty else { return }
        guard format == .zip || format == .sevenZ else {
            throw ArchiveOperationsError.invalidPassword("\(format.fileExtension) does not support passwords")
        }
        if format == .zip, password.utf8.count > 80 {
            throw ArchiveOperationsError.invalidPassword("ZIP passwords are limited to 80 UTF-8 bytes")
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
        destination: URL
    ) -> (executable: String, arguments: [String], currentDirectory: URL?) {
        let layout = ArchiveSourceLayout(items: items)
        switch format {
        case .zip:
            let arguments = ["-r", "-q", "-nw", destination.path, "--"] + layout.relativePaths
            return (tools["zip"]!, arguments, layout.workingDirectory)
        case .sevenZ:
            var arguments = ["a", "-t7z"]
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

    private func encryptedCreateInvocation(
        format: ServerArchiveFormat,
        tools: [String: String],
        items: [URL],
        destination: URL,
        password: String
    ) throws -> PtyProcessInvocation {
        let layout = ArchiveSourceLayout(items: items)
        switch format {
        case .zip:
            // AES-256 rather than Info-ZIP's ZipCrypto, which is broken
            // encryption and recoverable from a known plaintext fragment. The
            // password goes over the pty, never into process arguments.
            return PtyProcessInvocation(
                executable: tools["7z"]!,
                // No progress switch here: 7-Zip redraws progress over the
                // password prompt, and the prompt has to stay legible.
                arguments: ["a", "-tzip", "-mem=AES256", "-p", destination.path]
                    + layout.relativePaths,
                currentDirectory: layout.workingDirectory,
                password: password,
                responses: [.password, .password],
                minimumResponses: 1,
                passwordEchoPolicy: .disableBeforeResponse
            )
        case .sevenZ:
            return PtyProcessInvocation(
                executable: tools["7z"]!,
                arguments: ["a", "-t7z", "-bsp2", "-mhe=on", "-p", destination.path] + items.map(\.path),
                password: password,
                responses: [.password, .password],
                minimumResponses: 1,
                passwordEchoPolicy: .disableBeforeResponse
            )
        case .tarGz, .tarBz2, .tarXz:
            throw ArchiveOperationsError.invalidPassword("\(format.fileExtension) does not support passwords")
        }
    }

    private func tarCreateCommand(
        tool: String,
        flag: String,
        items: [URL],
        destination: URL
    ) -> (executable: String, arguments: [String], currentDirectory: URL?) {
        let layout = ArchiveSourceLayout(items: items)
        var arguments = ["-c\(flag)f", destination.path, "--"]
        arguments.append(contentsOf: layout.relativePaths)
        return (tool, arguments, layout.workingDirectory)
    }

    private func extractCommand(
        format: ServerArchiveFormat,
        tools: [String: String],
        archive: URL,
        destination: URL
    ) -> (executable: String, arguments: [String], currentDirectory: URL?) {
        switch format {
        case .zip:
            var arguments = ["-q"]
            arguments.append(contentsOf: [archive.path, "-d", destination.path])
            return (tools["unzip"]!, arguments, nil)
        case .sevenZ:
            var arguments = ["x", "-y", "-o\(destination.path)"]
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

    private func encryptedExtractInvocation(
        format: ServerArchiveFormat,
        tools: [String: String],
        archive: URL,
        destination: URL,
        password: String
    ) throws -> PtyProcessInvocation {
        switch format {
        case .zip:
            return PtyProcessInvocation(
                executable: tools["7z"]!,
                arguments: ["x", "-y", "-bsp2", "-o\(destination.path)", archive.path],
                password: password,
                responses: [.password],
                minimumResponses: 1,
                passwordEchoPolicy: .disableBeforeResponse
            )
        case .sevenZ:
            return PtyProcessInvocation(
                executable: tools["7z"]!,
                arguments: ["x", "-y", "-bsp2", "-o\(destination.path)", archive.path],
                password: password,
                responses: [.password],
                minimumResponses: 1,
                passwordEchoPolicy: .disableBeforeResponse
            )
        case .tarGz, .tarBz2, .tarXz:
            throw ArchiveOperationsError.invalidPassword("\(format.fileExtension) does not support passwords")
        }
    }

    /// Lists the archive's members before anything is extracted and refuses archives
    /// whose entries would escape the extraction directory, mirroring the client-side
    /// validation so a hostile archive cannot write outside its destination on the host.
    private func validateArchiveMembers(
        format: ServerArchiveFormat,
        tools: [String: String],
        archive: URL,
        password: String?
    ) throws {
        let members: [String]
        switch format {
        case .zip where !(password ?? "").isEmpty:
            // An encrypted zip is AES-256, which Info-ZIP cannot read at all, so
            // it is listed through 7-Zip. AES leaves entry names in the clear,
            // but the password still goes over the pty rather than into
            // arguments, and supplying it also surfaces a wrong password here
            // rather than part way through extracting.
            let invocation = PtyProcessInvocation(
                executable: tools["7z"]!,
                arguments: ["l", "-slt", archive.path],
                password: password,
                responses: [.password],
                minimumResponses: 1,
                passwordEchoPolicy: .disableBeforeResponse
            )
            let result = Self.serverResult(try runPtyProcess(invocation))
            guard result.status == 0 else {
                if Self.isWrongPasswordFailure(format: format, result: result) {
                    throw ArchiveOperationsError.wrongPassword
                }
                throw ArchiveOperationsError.processFailed(Self.errorMessage(result.stderr, fallback: format.fileExtension))
            }
            members = ArchiveToolDiagnostics.sevenZipListingMemberPaths(result.stderr, requireSeparator: true)
        case .zip:
            // The zip central directory is readable without the password.
            members = try memberListing(
                executable: tools["unzip"]!,
                arguments: ["-Z1", archive.path],
                format: format
            ).components(separatedBy: .newlines)
        case .sevenZ:
            if let password, !password.isEmpty {
                // Header-encrypted archives need the password to list; feed it over the
                // pty like extraction does so it never appears in process arguments.
                let invocation = PtyProcessInvocation(
                    executable: tools["7z"]!,
                    arguments: ["l", "-slt", archive.path],
                    password: password,
                    responses: [.password],
                    minimumResponses: 1,
                    passwordEchoPolicy: .disableBeforeResponse
                )
                let result = Self.serverResult(try runPtyProcess(invocation))
                guard result.status == 0 else {
                    if Self.isWrongPasswordFailure(format: format, result: result) {
                        throw ArchiveOperationsError.wrongPassword
                    }
                    throw ArchiveOperationsError.processFailed(Self.errorMessage(result.stderr, fallback: format.fileExtension))
                }
                members = ArchiveToolDiagnostics.sevenZipListingMemberPaths(result.stderr, requireSeparator: true)
            } else {
                // The bare -p supplies an empty password so a header-encrypted archive
                // fails immediately (surfacing the password prompt) instead of blocking
                // on an interactive prompt the daemon can never answer.
                members = ArchiveToolDiagnostics.sevenZipListingMemberPaths(
                    try memberListing(
                        executable: tools["7z"]!,
                        arguments: ["l", "-ba", "-slt", "-y", "-p", archive.path],
                        format: format
                    ),
                    requireSeparator: false
                )
            }
        case .tarGz:
            members = try memberListing(executable: tools["tar"]!, arguments: ["-tzf", archive.path], format: format)
                .components(separatedBy: .newlines)
        case .tarBz2:
            members = try memberListing(executable: tools["tar"]!, arguments: ["-tjf", archive.path], format: format)
                .components(separatedBy: .newlines)
        case .tarXz:
            members = try memberListing(executable: tools["tar"]!, arguments: ["-tJf", archive.path], format: format)
                .components(separatedBy: .newlines)
        }

        if let unsafe = ArchiveToolDiagnostics.firstUnsafeMemberPath(members) {
            throw ArchiveOperationsError.processFailed("Archive contains an unsafe path: \(unsafe)")
        }
    }

    private func memberListing(
        executable: String,
        arguments: [String],
        format: ServerArchiveFormat
    ) throws -> String {
        let result = try runListingProcess(executable, arguments)
        guard result.status == 0 else {
            let combined = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if Self.isWrongPasswordFailure(
                format: format,
                result: ServerProcessResult(status: result.status, stderr: combined)
            ) {
                throw ArchiveOperationsError.wrongPassword
            }
            throw ArchiveOperationsError.processFailed(Self.errorMessage(combined, fallback: format.fileExtension))
        }
        return result.stdout
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

    private static func serverResult(_ result: PtyProcessResult) -> ServerProcessResult {
        ServerProcessResult(status: result.status, stderr: result.outputString)
    }

    private static func isWrongPasswordFailure(
        format: ServerArchiveFormat,
        result: ServerProcessResult
    ) -> Bool {
        switch format {
        case .zip:
            // An encrypted zip is now written and read by 7-Zip, so a wrong
            // password can be reported in either tool's words: 7-Zip's for an
            // AES archive, Info-ZIP's for one made before that change or
            // somewhere else. Both mean the same thing to the user, who should
            // be asked again rather than shown a process failure.
            return ArchiveToolDiagnostics.isZipPasswordFailure(message: result.stderr, status: result.status)
                || ArchiveToolDiagnostics.isSevenZipPasswordMessage(result.stderr)
        case .sevenZ:
            return ArchiveToolDiagnostics.isSevenZipPasswordMessage(result.stderr)
        case .tarGz, .tarBz2, .tarXz:
            return false
        }
    }

    /// Names a tool may go by, most preferred first.
    ///
    /// 7-Zip ships as `7zz` from its own project, which is what macOS installs,
    /// and as `7z` from p7zip, which is what most Linux distributions carry.
    /// Either can do the work, so both are accepted rather than making the
    /// archive features depend on which packaging a host happens to have.
    private static func toolCandidates(_ tool: String) -> [String] {
        tool == "7z" ? ["7z", "7zz"] : [tool]
    }

    /// Directories checked when PATH does not name the tool.
    ///
    /// A helper started over a non-login SSH session, or an app launched by the
    /// window server, inherits a thin PATH that often omits where package
    /// managers install things. Refusing to build an archive because of that
    /// would be a poor answer when the tool is sitting in an obvious place.
    private static let wellKnownToolDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/opt/local/bin",
    ]

    private static func resolveToolOnPath(_ tool: String) -> String? {
        for candidate in toolCandidates(tool) {
            if let path = lookUpOnPath(candidate) { return path }
        }
        for candidate in toolCandidates(tool) {
            for directory in wellKnownToolDirectories {
                let path = directory + "/" + candidate
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    private static func lookUpOnPath(_ tool: String) -> String? {
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

    private static func runListingProcess(
        executable: String,
        arguments: [String]
    ) throws -> ServerListingResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let outputDrain = PipeDrain.start(reading: outputPipe.fileHandleForReading)
        let errorDrain = PipeDrain.start(reading: errorPipe.fileHandleForReading)
        process.waitUntilExit()

        let outputData = outputDrain.wait()
        let errorData = errorDrain.wait()
        return ServerListingResult(
            status: process.terminationStatus,
            stdout: String(data: outputData, encoding: .utf8) ?? String(data: outputData, encoding: .isoLatin1) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? String(data: errorData, encoding: .isoLatin1) ?? ""
        )
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
        #if os(Linux)
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C.UTF-8"
        process.environment = environment
        #endif

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()

        let drain = PipeDrain.start(reading: errorPipe.fileHandleForReading)
        process.waitUntilExit()

        let data = drain.wait()
        let stderr = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return ServerProcessResult(status: process.terminationStatus, stderr: stderr)
    }
}
