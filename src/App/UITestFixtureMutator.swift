import Foundation

enum UITestFixtureMutator {
    private static let sentinelName = ".detours-qualification-root.json"

    static func perform(_ command: UITestEnvironment.FixtureMutationCommand) throws {
        guard UITestEnvironment.isEnabled,
              let root = UITestEnvironment.rootDirectory?.standardizedFileURL else {
            throw MutationError.unavailableRoot
        }
        let sentinel = root.appendingPathComponent(sentinelName)
        guard FileManager.default.fileExists(atPath: sentinel.path) else {
            throw MutationError.missingSentinel(sentinel.path)
        }

        let source = try validatedURL(command.relativePath, under: root, mayNotExist: command.action != "remove")
        switch command.action {
        case "createDirectory":
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        case "write":
            guard let contents = command.contents else { throw MutationError.missingContents }
            try Data(contents.utf8).write(to: source)
        case "move":
            guard let destinationPath = command.destinationRelativePath else {
                throw MutationError.missingDestination
            }
            let destination = try validatedURL(destinationPath, under: root, mayNotExist: true)
            try FileManager.default.moveItem(at: source, to: destination)
        case "importFile":
            // The XCUI runner is sandboxed and cannot write into the guarded root, so a
            // fixture built with an external tool is produced in the runner's own temporary
            // directory and imported here, inside the already-consented app. `contents`
            // carries the absolute source path.
            guard let externalPath = command.contents else { throw MutationError.missingContents }
            let external = URL(fileURLWithPath: externalPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: external.path) else {
                throw MutationError.missingImportSource(external.path)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.removeItem(at: source)
            }
            try FileManager.default.copyItem(at: external, to: source)
        case "remove":
            try FileManager.default.removeItem(at: source)
        case "gitInit":
            try runGit(["init", "-q"], in: source)
            try runGit(["add", "tracked.txt"], in: source)
            try runGit([
                "-c", "user.name=Detours Qualification",
                "-c", "user.email=qualification@detours.invalid",
                "commit", "-q", "-m", "initial fixture",
            ], in: source)
        default:
            throw MutationError.unknownAction(command.action)
        }
    }

    private static func validatedURL(
        _ relativePath: String,
        under root: URL,
        mayNotExist: Bool
    ) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw MutationError.invalidRelativePath(relativePath)
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix), candidate.path != root.path else {
            throw MutationError.escapedRoot(candidate.path)
        }

        var current = root
        let components = candidate.pathComponents.dropFirst(root.pathComponents.count)
        for component in components {
            current.appendPathComponent(component)
            if !FileManager.default.fileExists(atPath: current.path) {
                if mayNotExist { break }
                throw MutationError.missingPath(current.path)
            }
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
            if values.isSymbolicLink == true || values.isAliasFile == true {
                throw MutationError.indirectPath(current.path)
            }
        }
        return candidate
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MutationError.commandFailed(
                (["git"] + arguments).joined(separator: " "),
                process.terminationStatus,
                detail
            )
        }
    }
}

private enum MutationError: LocalizedError {
    case unavailableRoot
    case missingSentinel(String)
    case invalidRelativePath(String)
    case escapedRoot(String)
    case missingPath(String)
    case indirectPath(String)
    case missingContents
    case missingDestination
    case missingImportSource(String)
    case unknownAction(String)
    case commandFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .unavailableRoot: "The UI-test fixture root is unavailable."
        case .missingSentinel(let path): "The qualification sentinel is missing at " + path
        case .invalidRelativePath(let path): "The fixture path is not relative: " + path
        case .escapedRoot(let path): "The fixture path escaped its guarded root: " + path
        case .missingPath(let path): "The fixture path does not exist: " + path
        case .indirectPath(let path): "The fixture path contains an alias or symbolic link: " + path
        case .missingContents: "The fixture write has no contents."
        case .missingDestination: "The fixture move has no destination."
        case .missingImportSource(let path): "The fixture import source does not exist: " + path
        case .unknownAction(let action): "Unknown fixture mutation action: " + action
        case .commandFailed(let command, let status, let detail):
            command + " exited " + String(status) + ": " + detail
        }
    }
}
