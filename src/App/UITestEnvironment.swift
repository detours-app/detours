import Foundation

enum UITestEnvironment {
    static let resizeMainWindowCommandFileName = ".detours-resize-main-window.json"

    struct ResizeMainWindowCommand: Decodable {
        let id: String
        let width: Double
        let height: Double
    }

    static var isEnabled: Bool {
        guard let root = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_ROOT"] else {
            return false
        }
        return !root.isEmpty
    }

    /// Remote-tab seam for the remote-aware Quick Open UI tests. `DETOURS_UI_TEST_REMOTE` is
    /// `connected` or `disconnected`; absent means the standard local-only test session.
    enum RemoteMode: String {
        case connected
        case disconnected
    }

    static var remoteMode: RemoteMode? {
        guard isEnabled, let raw = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_REMOTE"] else {
            return nil
        }
        return RemoteMode(rawValue: raw)
    }

    /// Stable host identity for the UI-test remote so the seam and tests agree on the display name.
    static let remoteHostDisplayName = "UITest Server"

    static var rootDirectory: URL? {
        guard let root = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_ROOT"], !root.isEmpty else {
            return nil
        }

        let url: URL
        if root.hasPrefix("/") {
            url = URL(fileURLWithPath: root)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(root)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return url
    }

    static var resizeMainWindowCommandURL: URL? {
        rootDirectory?.appendingPathComponent(resizeMainWindowCommandFileName)
    }

    static func currentResizeMainWindowCommand() -> ResizeMainWindowCommand? {
        guard let url = resizeMainWindowCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(ResizeMainWindowCommand.self, from: data)
    }
}
