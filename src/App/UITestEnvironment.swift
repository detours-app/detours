import Foundation

enum UITestEnvironment {
    static let resizeMainWindowCommandFileName = ".detours-resize-main-window.json"
    static let renameItemCommandFileName = ".detours-rename-item.json"
    static let showNetworkShareDialogCommandFileName = ".detours-show-network-share-dialog.json"
    static let showNetworkShareDialogAcknowledgementFileName = ".detours-show-network-share-dialog-presented.json"
    static let dismissNetworkShareDialogCommandFileName = ".detours-dismiss-network-share-dialog.json"
    static let showNetworkShareDialogDismissedFileName = ".detours-show-network-share-dialog-dismissed.json"
    static let quickNavCommandFileName = ".detours-quick-nav-command.json"

    struct ResizeMainWindowCommand: Decodable {
        let id: String
        let width: Double
        let height: Double
    }

    struct RenameItemCommand: Decodable {
        let id: String
        let relativePath: String
        let newName: String
    }

    struct ShowNetworkShareDialogCommand: Decodable {
        let id: String
        let dismissAfterPresentationDelayMilliseconds: Int?
    }

    struct DismissNetworkShareDialogCommand: Decodable {
        let id: String
    }

    struct QuickNavCommand: Decodable {
        let id: String
        let query: String
        let action: String?
    }

    struct ShowNetworkShareDialogAcknowledgement: Encodable {
        let id: String
    }

    struct ShowNetworkShareDialogDismissalAcknowledgement: Encodable {
        let id: String
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

    static var disablesInlineRename: Bool {
        guard isEnabled else { return false }
        return ProcessInfo.processInfo.environment["DETOURS_UI_TEST_DISABLE_INLINE_RENAME"] == "1"
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

    static var renameItemCommandURL: URL? {
        rootDirectory?.appendingPathComponent(renameItemCommandFileName)
    }

    static var showNetworkShareDialogCommandURL: URL? {
        rootDirectory?.appendingPathComponent(showNetworkShareDialogCommandFileName)
    }

    static var showNetworkShareDialogAcknowledgementURL: URL? {
        rootDirectory?.appendingPathComponent(showNetworkShareDialogAcknowledgementFileName)
    }

    static var dismissNetworkShareDialogCommandURL: URL? {
        rootDirectory?.appendingPathComponent(dismissNetworkShareDialogCommandFileName)
    }

    static var showNetworkShareDialogDismissedURL: URL? {
        rootDirectory?.appendingPathComponent(showNetworkShareDialogDismissedFileName)
    }

    static var quickNavCommandURL: URL? {
        rootDirectory?.appendingPathComponent(quickNavCommandFileName)
    }

    static func currentResizeMainWindowCommand() -> ResizeMainWindowCommand? {
        guard let url = resizeMainWindowCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(ResizeMainWindowCommand.self, from: data)
    }

    static func currentRenameItemCommand() -> RenameItemCommand? {
        guard let url = renameItemCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(RenameItemCommand.self, from: data)
    }

    static func currentShowNetworkShareDialogCommand() -> ShowNetworkShareDialogCommand? {
        guard let url = showNetworkShareDialogCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(ShowNetworkShareDialogCommand.self, from: data)
    }

    static func currentDismissNetworkShareDialogCommand() -> DismissNetworkShareDialogCommand? {
        guard let url = dismissNetworkShareDialogCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(DismissNetworkShareDialogCommand.self, from: data)
    }

    static func currentQuickNavCommand() -> QuickNavCommand? {
        guard let url = quickNavCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(QuickNavCommand.self, from: data)
    }

    static func acknowledgeShowNetworkShareDialogCommand(id: String) {
        guard let url = showNetworkShareDialogAcknowledgementURL,
              let data = try? JSONEncoder().encode(ShowNetworkShareDialogAcknowledgement(id: id)) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func acknowledgeShowNetworkShareDialogDismissed(id: String) {
        guard let url = showNetworkShareDialogDismissedURL,
              let data = try? JSONEncoder().encode(ShowNetworkShareDialogDismissalAcknowledgement(id: id)) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }
}
