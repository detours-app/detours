import Foundation

struct QuickNavResult: Equatable, Identifiable {
    let location: Location
    let title: String
    let subtitle: String
    let hostLabel: String?
    let isConnected: Bool
    let score: Double
    let isDirectory: Bool

    var id: Location { location }

    var isRemote: Bool {
        if case .remote = location { return true }
        return false
    }

    var localURL: URL? {
        if case .local(let url) = location { return url }
        return nil
    }

    static func local(url: URL, score: Double, isDirectory: Bool) -> QuickNavResult {
        QuickNavResult(
            location: .local(url),
            title: url.lastPathComponent,
            subtitle: displayPath(for: url),
            hostLabel: nil,
            isConnected: true,
            score: score,
            isDirectory: isDirectory
        )
    }

    static func remote(
        location: Location,
        host: RemoteHost?,
        isConnected: Bool,
        score: Double
    ) -> QuickNavResult {
        QuickNavResult(
            location: location,
            title: location.lastPathComponent,
            subtitle: location.path,
            hostLabel: host?.displayName ?? "Unknown Host",
            isConnected: isConnected,
            score: score,
            isDirectory: true
        )
    }

    private static func displayPath(for url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
