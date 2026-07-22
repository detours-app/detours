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
            try await provider.createDirectory(at: scenario, withIntermediateDirectories: false)
            do {
                try await upload(
                    Data(sentinelID.utf8),
                    to: childLocation(sentinelName, scenarioPath: scenarioPath, hostID: hostID),
                    provider: provider
                )
            } catch {
                try? await provider.delete([scenario])
                throw error
            }
            return nil
        case "createDirectory", "write", "move", "remove", "cleanup":
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
            case "cleanup":
                try await provider.delete([scenario])
            default:
                break
            }
            return nil
        default:
            throw MutationError.unknownAction(command.action)
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
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-remote-upload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        try await provider.upload(temporary, to: location)
    }

    private static func lastPathComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
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
            case .sentinelMismatch(let path): "The remote fixture sentinel did not match: \(path)"
            case .unknownAction(let action): "Unknown remote fixture mutation action: \(action)"
            }
        }
    }
}
