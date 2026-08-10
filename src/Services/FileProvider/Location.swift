import Foundation

enum Location: Hashable, Codable, Sendable {
    case local(URL)
    case remote(hostID: UUID, path: String)

    var url: URL {
        switch self {
        case .local(let url):
            return url
        case .remote:
            fatalError("Remote locations do not have local file URLs")
        }
    }

    /// Builds a file URL for a path that lives on another machine.
    ///
    /// `URL(fileURLWithPath:)` stats the path to decide whether it is a
    /// directory, and for a remote path such as /home/... that stat goes
    /// through the local automounter and costs about twelve milliseconds. A
    /// remote path never exists locally, so the answer is worthless as well as
    /// expensive. Declaring it keeps the conversion in memory. Always false, so
    /// two URLs for the same remote path always compare equal.
    static func remoteFileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }

    var lastPathComponent: String {
        switch self {
        case .local(let url):
            return url.lastPathComponent
        case .remote(_, let path):
            return Self.remoteFileURL(path).lastPathComponent
        }
    }

    var path: String {
        switch self {
        case .local(let url):
            return url.path
        case .remote(_, let path):
            return path
        }
    }

    var parent: Location {
        deletingLastPathComponent()
    }

    func appendingPathComponent(_ component: String) -> Location {
        switch self {
        case .local(let url):
            return .local(url.appendingPathComponent(component))
        case .remote(let hostID, let path):
            return .remote(hostID: hostID, path: Self.joinRemotePath(path, component))
        }
    }

    func deletingLastPathComponent() -> Location {
        switch self {
        case .local(let url):
            return .local(url.deletingLastPathComponent())
        case .remote(let hostID, let path):
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty else {
                return .remote(hostID: hostID, path: "/")
            }
            let components = trimmed.split(separator: "/").dropLast()
            let parent = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
            return .remote(hostID: hostID, path: parent)
        }
    }

    private static func joinRemotePath(_ base: String, _ component: String) -> String {
        let trimmedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base == "/" {
            return "/" + trimmedComponent
        }
        return "/" + base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + trimmedComponent
    }

    static func == (lhs: Location, rhs: Location) -> Bool {
        switch (lhs, rhs) {
        case (.local(let lhsURL), .local(let rhsURL)):
            return lhsURL.standardizedFileURL.path == rhsURL.standardizedFileURL.path
        case (.remote(let lhsHost, let lhsPath), .remote(let rhsHost, let rhsPath)):
            return lhsHost == rhsHost && normalizedRemotePath(lhsPath) == normalizedRemotePath(rhsPath)
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .local(let url):
            hasher.combine("local")
            hasher.combine(url.standardizedFileURL.path)
        case .remote(let hostID, let path):
            hasher.combine("remote")
            hasher.combine(hostID)
            hasher.combine(Self.normalizedRemotePath(path))
        }
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/" + trimmed
    }
}
