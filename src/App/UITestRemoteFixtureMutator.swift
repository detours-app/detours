import Foundation

@MainActor
enum UITestRemoteFixtureMutator {
    private static let sentinelName = ".detours-qualification-root.json"
    private static let scenarioPrefix = "QualificationRefresh-"

    static func perform(
        _ command: UITestEnvironment.RemoteFixtureMutationCommand,
        splitViewController: MainSplitViewController
    ) async throws -> [String]? {
        guard UITestEnvironment.isEnabled,
              let current = splitViewController.leftPane.selectedTab?
                .fileListViewController.currentRemoteLocation,
              case .remote(let hostID, let currentPath) = current else {
            throw MutationError.unavailablePane
        }
        let scenarioPath = try validatedScenarioPath(
            homePath: command.homePath,
            scenarioName: command.scenarioName,
            currentPath: currentPath
        )
        let provider = try FileOperationQueue.shared.remoteProvider(for: hostID)
        let home = Location.remote(hostID: hostID, path: command.homePath)
        let scenario = Location.remote(hostID: hostID, path: scenarioPath)

        switch command.action {
        case "snapshot":
            let entries = try await provider.list(home, showHidden: true)
            return entries.map { lastPathComponent($0.location.path) }.sorted()
        case "createScenario":
            guard let sentinelID = command.sentinelID, UUID(uuidString: sentinelID) != nil else {
                throw MutationError.invalidSentinel
            }
            let existing = try await provider.list(home, showHidden: true)
            guard !existing.contains(where: { $0.location == scenario }) else {
                throw MutationError.scenarioExists(scenarioPath)
            }
            _ = try await FileOperationQueue.shared.createFolder(in: home, name: command.scenarioName)
            do {
                _ = try await FileOperationQueue.shared.createFile(in: scenario, name: sentinelName, content: Data(sentinelID.utf8))
            } catch {
                try await trashFixture(scenario, hostID: hostID)
                throw error
            }
            return nil
        case "createDirectory", "write", "move", "remove", "gitInit", "symlink", "stat", "fingerprint", "cleanup":
            guard let sentinelID = command.sentinelID, UUID(uuidString: sentinelID) != nil else {
                throw MutationError.invalidSentinel
            }
            try await verifySentinel(
                sentinelID,
                scenarioPath: scenarioPath,
                hostID: hostID,
                provider: provider
            )
            switch command.action {
            case "createDirectory":
                let location = try validatedChildLocation(
                    command.relativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                try await provider.createDirectory(at: location, withIntermediateDirectories: false)
            case "write":
                guard let contents = command.contents else { throw MutationError.missingContents }
                let location = try validatedChildLocation(
                    command.relativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                try await upload(Data(contents.utf8), to: location, provider: provider)
            case "move":
                let source = try validatedChildLocation(
                    command.relativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                let destination = try validatedChildLocation(
                    command.destinationRelativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                guard source.deletingLastPathComponent() == destination.deletingLastPathComponent() else {
                    throw MutationError.crossDirectoryMove
                }
                _ = try await provider.rename(source, to: lastPathComponent(destination.path))
            case "remove":
                let location = try validatedChildLocation(
                    command.relativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                try await provider.delete([location])
            case "gitInit":
                guard UITestEnvironment.realRemoteContext != "WINDOWS_TARGET",
                      let target = UITestEnvironment.realRemoteTarget else {
                    throw MutationError.gitUnavailable
                }
                let path = shellQuote(scenarioPath)
                let command = "git -C " + path + " init -q"
                    + " && git -C " + path + " add tracked.txt"
                    + " && git -C " + path
                    + " -c user.name='Detours Qualification'"
                    + " -c user.email=qualification@detours.invalid"
                    + " commit -q -m 'initial fixture'"
                _ = try await SSHRemoteHostKindProbeClient(sshTarget: target).run(command)
            case "symlink":
                // Symlinks are created over SSH: the provider has no call for them, and the
                // Windows target has no `ln`.
                guard UITestEnvironment.realRemoteContext != "WINDOWS_TARGET",
                      let target = UITestEnvironment.realRemoteTarget else {
                    throw MutationError.symlinkUnavailable
                }
                let link = try validatedChildLocation(
                    command.relativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                let destination = try validatedChildLocation(
                    command.destinationRelativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                let command = "ln -s " + shellQuote(destination.path) + " " + shellQuote(link.path)
                _ = try await SSHRemoteHostKindProbeClient(sshTarget: target).run(command)
            case "stat":
                // Reports what the host holds at the path: "directory", "link" or "file".
                let location = try validatedChildLocation(
                    command.relativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                let entry = try await provider.stat(location)
                return [entry.isSymbolicLink ? "link" : entry.isDirectory ? "directory" : "file"]
            case "fingerprint":
                // Reports byte-exact filesystem evidence for the host's current file: its kind,
                // byte count and SHA-256, read inside the app so a sandboxed runner can compare
                // payloads without writing into the guarded fixture.
                let location = try validatedChildLocation(
                    command.relativePath,
                    scenarioPath: scenarioPath,
                    hostID: hostID
                )
                let entry = try await provider.stat(location)
                if entry.isSymbolicLink { return ["link"] }
                if entry.isDirectory { return ["directory"] }
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("detours-fixture-fingerprint-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await provider.download(location, to: temporary)
                let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let digest = try ServerDeployer.sha256Hex(of: temporary)
                return ["file", String(size), digest]
            case "cleanup":
                try await trashFixture(scenario, hostID: hostID)
            default:
                break
            }
            return nil
        default:
            throw MutationError.unknownAction(command.action)
        }
    }

    private static func trashFixture(_ location: Location, hostID: UUID) async throws {
        let queue = FileOperationQueue.shared
        try await queue.enqueue(remoteHosts: [hostID]) {
            let result = try await queue.performAcceptedRemoval([location], permanently: false)
            try queue.requireSuccessfulBatch(result)
        }
    }

    private static func validatedScenarioPath(
        homePath: String,
        scenarioName: String,
        currentPath: String
    ) throws -> String {
        guard !homePath.isEmpty, homePath.hasPrefix("/"), !homePath.hasSuffix("/") else {
            throw MutationError.invalidHome(homePath)
        }
        guard scenarioName.hasPrefix(scenarioPrefix),
              UUID(uuidString: String(scenarioName.dropFirst(scenarioPrefix.count))) != nil else {
            throw MutationError.invalidScenarioName(scenarioName)
        }
        let scenarioPath = homePath + "/" + scenarioName
        guard currentPath == homePath || currentPath == scenarioPath || currentPath.hasPrefix(scenarioPath + "/") else {
            throw MutationError.paneEscapedHome(currentPath)
        }
        return scenarioPath
    }

    private static func validatedChildLocation(
        _ relativePath: String?,
        scenarioPath: String,
        hostID: UUID
    ) throws -> Location {
        guard let relativePath,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            throw MutationError.invalidRelativePath(relativePath ?? "nil")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MutationError.invalidRelativePath(relativePath)
        }
        return Location.remote(hostID: hostID, path: scenarioPath + "/" + relativePath)
    }

    private static func childLocation(_ name: String, scenarioPath: String, hostID: UUID) -> Location {
        Location.remote(hostID: hostID, path: scenarioPath + "/" + name)
    }

    private static func verifySentinel(
        _ expected: String,
        scenarioPath: String,
        hostID: UUID,
        provider: any FileProvider
    ) async throws {
        let location = childLocation(sentinelName, scenarioPath: scenarioPath, hostID: hostID)
        if let windowsProvider = provider as? WindowsRemoteProvider {
            let data = try await windowsProvider.readSmallControlFile(location)
            guard String(data: data, encoding: .utf8) == expected else {
                throw MutationError.sentinelMismatch(scenarioPath)
            }
            return
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-remote-sentinel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await provider.download(location, to: temporary)
        let actual = try String(contentsOf: temporary, encoding: .utf8)
        guard actual == expected else { throw MutationError.sentinelMismatch(scenarioPath) }
    }

    private static func upload(
        _ data: Data,
        to location: Location,
        provider: any FileProvider
    ) async throws {
        if let windowsProvider = provider as? WindowsRemoteProvider {
            try await windowsProvider.writeSmallControlFile(
                data,
                to: location,
                hidden: lastPathComponent(location.path).hasPrefix(".")
            )
            return
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-remote-upload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        try await provider.upload(temporary, to: location)
    }

    private static func lastPathComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    enum MutationError: LocalizedError {
        case unavailablePane
        case invalidHome(String)
        case invalidScenarioName(String)
        case paneEscapedHome(String)
        case invalidRelativePath(String)
        case invalidSentinel
        case scenarioExists(String)
        case missingContents
        case crossDirectoryMove
        case gitUnavailable
        case symlinkUnavailable
        case sentinelMismatch(String)
        case unknownAction(String)

        var errorDescription: String? {
            switch self {
            case .unavailablePane: "The live remote pane is unavailable."
            case .invalidHome(let path): "Invalid remote fixture home: \(path)"
            case .invalidScenarioName(let name): "Invalid remote fixture scenario: \(name)"
            case .paneEscapedHome(let path): "The remote pane escaped the fixture home: \(path)"
            case .invalidRelativePath(let path): "Invalid remote fixture relative path: \(path)"
            case .invalidSentinel: "The remote fixture sentinel is invalid."
            case .scenarioExists(let path): "The remote fixture scenario already exists: \(path)"
            case .missingContents: "The remote fixture write has no contents."
            case .crossDirectoryMove: "The remote fixture move crossed directories."
            case .gitUnavailable: "The remote fixture Git setup is unavailable."
            case .symlinkUnavailable: "The remote fixture symlink setup is unavailable."
            case .sentinelMismatch(let path): "The remote fixture sentinel did not match: \(path)"
            case .unknownAction(let action): "Unknown remote fixture mutation action: \(action)"
            }
        }
    }
}
