import Foundation

enum WindowsPathError: Error, Equatable {
    case expectedRemote(Location)
    case invalidDrivePath(String)
    case nativePathRequired(String)
    case parentTraversal(String)
}

struct WindowsPath: Equatable, Sendable {
    static let syntheticRoot = "/"

    let remotePath: String

    init(remotePath: String) throws {
        self.remotePath = try Self.normalizedRemotePath(remotePath)
    }

    private init(validatedRemotePath: String) {
        remotePath = validatedRemotePath
    }

    init(location: Location, hostID: UUID) throws {
        guard case .remote(let locationHostID, let path) = location, locationHostID == hostID else {
            throw WindowsPathError.expectedRemote(location)
        }
        try self.init(remotePath: path)
    }

    var isSyntheticRoot: Bool {
        remotePath == Self.syntheticRoot
    }

    var isDriveRoot: Bool {
        Self.driveLetter(in: remotePath) != nil && components.count == 1
    }

    var nativePath: String? {
        guard !isSyntheticRoot else { return nil }
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let native = trimmed.replacingOccurrences(of: "/", with: "\\")
        return isDriveRoot ? native + "\\" : native
    }

    var sftpPath: String? {
        guard !isSyntheticRoot else { return nil }
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return isDriveRoot ? trimmed + "/" : trimmed
    }

    var parent: WindowsPath {
        if isSyntheticRoot || isDriveRoot {
            return WindowsPath(validatedRemotePath: Self.syntheticRoot)
        }
        let parentComponents = components.dropLast()
        let parent = parentComponents.isEmpty ? Self.syntheticRoot : "/" + parentComponents.joined(separator: "/")
        return WindowsPath(validatedRemotePath: parent)
    }

    func appending(_ component: String) throws -> WindowsPath {
        let cleaned = component
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty else { return self }
        guard !cleaned.split(separator: "/").contains("..") else {
            throw WindowsPathError.parentTraversal(component)
        }
        if isSyntheticRoot {
            return try WindowsPath(remotePath: "/" + cleaned)
        }
        return try WindowsPath(remotePath: remotePath + "/" + cleaned)
    }

    static func remotePath(fromNative nativePath: String) throws -> String {
        let normalized = nativePath.replacingOccurrences(of: "\\", with: "/")
        return try normalizedRemotePath(normalized.hasPrefix("/") ? normalized : "/" + normalized)
    }

    static func location(fromNative nativePath: String, hostID: UUID) throws -> Location {
        .remote(hostID: hostID, path: try remotePath(fromNative: nativePath))
    }

    static func normalizedRemotePath(_ path: String) throws -> String {
        let slashPath = path.replacingOccurrences(of: "\\", with: "/")
        let trimmed = slashPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return Self.syntheticRoot }

        let segments = trimmed.split(separator: "/").map(String.init)
        guard !segments.contains("..") else {
            throw WindowsPathError.parentTraversal(path)
        }

        let firstComponent = segments.first ?? ""
        guard isDriveComponent(firstComponent) else {
            throw WindowsPathError.invalidDrivePath(path)
        }
        return "/" + trimmed
    }

    private var components: [String] {
        remotePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
    }

    private static func driveLetter(in path: String) -> Character? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let first = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard isDriveComponent(first), let letter = first.first else { return nil }
        return letter
    }

    private static func isDriveComponent(_ component: String) -> Bool {
        guard component.count == 2, component.last == ":" else { return false }
        guard let first = component.first else { return false }
        return first.isLetter
    }
}
