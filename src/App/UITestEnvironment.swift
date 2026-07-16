import Foundation

enum UITestEnvironment {
    static let resizeMainWindowCommandFileName = ".detours-resize-main-window.json"
    static let renameItemCommandFileName = ".detours-rename-item.json"
    static let showNetworkShareDialogCommandFileName = ".detours-show-network-share-dialog.json"
    static let showNetworkShareDialogAcknowledgementFileName = ".detours-show-network-share-dialog-presented.json"
    static let dismissNetworkShareDialogCommandFileName = ".detours-dismiss-network-share-dialog.json"
    static let showNetworkShareDialogDismissedFileName = ".detours-show-network-share-dialog-dismissed.json"
    static let quickNavCommandFileName = ".detours-quick-nav-command.json"
    static let remoteFailureCommandFileName = ".detours-remote-failure.json"
    static let remoteFailureAcknowledgementFileName = ".detours-remote-failure-ack.json"
    static let undoMenuTitleRequestFileName = ".detours-undo-menu-title-request.json"
    static let undoMenuTitleResponseFileName = ".detours-undo-menu-title-response.json"
    static let duplicateStructureShowRequestFileName = ".detours-duplicate-structure-show-request.json"
    static let duplicateStructurePresentedFileName = ".detours-duplicate-structure-presented.json"
    static let duplicateStructureActionFileName = ".detours-duplicate-structure-action.json"
    static let duplicateStructureDismissedFileName = ".detours-duplicate-structure-dismissed.json"
    static let appearanceSettingsCommandFileName = ".detours-appearance-settings.json"
    static let appearanceSettingsAcknowledgementFileName = ".detours-appearance-settings-applied.json"
    static let paneStateRequestFileName = ".detours-pane-state-request.json"
    static let paneStateResponseFileName = ".detours-pane-state-response.json"
    static let openedItemsHistoryFileName = ".detours-opened-items-history.json"
    static let remoteMutationCommandFileName = ".detours-remote-mutation-command.json"
    static let keychainLifecycleResultFileName = ".detours-keychain-lifecycle-result.json"

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

    struct RemoteFailureCommand: Decodable {
        let id: String
    }

    struct UndoMenuTitleRequest: Decodable {
        let id: String
    }

    struct DuplicateStructureShowRequest: Decodable {
        let id: String
        let relativePath: String
    }

    struct DuplicateStructureAction: Decodable {
        let id: String
        let action: String
    }

    struct AppearanceSettingsCommand: Decodable {
        let id: String
        let theme: String
        let fontSize: Int
        let fileListRowDensity: String
    }

    struct PaneStateRequest: Decodable {
        let id: String
        let pane: String
    }

    struct RemoteMutationCommand: Decodable {
        let id: String
        let sourcePath: String
        let newName: String
    }

    struct KeychainLifecycleResult: Encodable {
        let success: Bool
        let failure: String?
    }

    struct ShowNetworkShareDialogAcknowledgement: Encodable {
        let id: String
    }

    struct NetworkShareDismissalAck: Encodable {
        let id: String
    }

    struct RemoteFailureAcknowledgement: Encodable {
        let id: String
        let handled: Bool
    }

    struct UndoMenuTitleResponse: Encodable {
        let id: String
        let title: String
    }

    struct DuplicateStructurePresentation: Encodable {
        let id: String
        let sourceName: String
        let folderName: String
    }

    struct DuplicateStructureDismissal: Encodable {
        let id: String
    }

    struct AppearanceSettingsAcknowledgement: Encodable {
        let id: String
        let applied: Bool
        let checkedTextCount: Int
        let failure: String?
    }

    struct PaneStateResponse: Encodable {
        let id: String
        let pane: String
        let displayedLocation: String?
        let expandedLocations: [String]
        let selectedLocations: [String]
        let topVisibleLocation: String?
        let topVisibleOffset: Double
        let horizontalOffset: Double
        let focus: String
        let filterText: String
        let filterVisible: Bool
        let sortColumn: String
        let sortAscending: Bool
        let activeDropTarget: String?
        let refreshInFlight: Bool
        let visibleRowCount: Int
    }

    static var isEnabled: Bool {
        guard let root = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_ROOT"] else {
            return false
        }
        return !root.isEmpty
    }

    /// Remote-tab seam for the remote-aware Quick Open UI tests. `DETOURS_UI_TEST_REMOTE` is
    /// `connected`, `disconnected`, or `windows-failed`; absent means the standard local-only
    /// test session.
    enum RemoteMode: String {
        case connected
        case disconnected
        case windowsFailed = "windows-failed"
    }

    static var remoteMode: RemoteMode? {
        guard isEnabled, let raw = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_REMOTE"] else {
            return nil
        }
        return RemoteMode(rawValue: raw)
    }

    static var recordsOpenedItems: Bool {
        guard isEnabled else { return false }
        return ProcessInfo.processInfo.environment["DETOURS_UI_TEST_RECORD_OPENS"] == "1"
    }

    static var runsKeychainLifecycle: Bool {
        guard isEnabled else { return false }
        return ProcessInfo.processInfo.environment["DETOURS_UI_TEST_KEYCHAIN_LIFECYCLE"] == "1"
    }

    static var mirrorsRemoteInBothPanes: Bool {
        guard isEnabled else { return false }
        return ProcessInfo.processInfo.environment["DETOURS_UI_TEST_REMOTE_BOTH_PANES"] == "1"
    }

    static var usesSecondRemoteHost: Bool {
        guard isEnabled else { return false }
        return ProcessInfo.processInfo.environment["DETOURS_UI_TEST_REMOTE_SECOND_HOST"] == "1"
    }

    /// A Foundry-only UI integration target. Unlike `remoteMode`, this goes through the normal
    /// SSH deployment, connection, RPC, transfer, and watcher stack.
    static var realRemoteTarget: String? {
        guard isEnabled,
              let target = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_REAL_REMOTE_TARGET"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            return nil
        }
        return target
    }

    static var realRemoteConnectionDelay: Duration? {
        guard realRemoteTarget != nil,
              let rawValue = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_REMOTE_CONNECT_DELAY_MS"],
              let milliseconds = Int64(rawValue), milliseconds > 0 else {
            return nil
        }
        return .milliseconds(milliseconds)
    }

    /// Stable host identity for the UI-test remote so the seam and tests agree on the display name.
    static let remoteHostDisplayName = "UITest Server"
    static let windowsRemoteHostDisplayName = "UITest Windows"

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

    static var remoteFailureCommandURL: URL? {
        rootDirectory?.appendingPathComponent(remoteFailureCommandFileName)
    }

    static var remoteFailureAcknowledgementURL: URL? {
        rootDirectory?.appendingPathComponent(remoteFailureAcknowledgementFileName)
    }

    static var undoMenuTitleRequestURL: URL? {
        rootDirectory?.appendingPathComponent(undoMenuTitleRequestFileName)
    }

    static var undoMenuTitleResponseURL: URL? {
        rootDirectory?.appendingPathComponent(undoMenuTitleResponseFileName)
    }

    static var duplicateStructureShowRequestURL: URL? {
        rootDirectory?.appendingPathComponent(duplicateStructureShowRequestFileName)
    }

    static var duplicateStructurePresentedURL: URL? {
        rootDirectory?.appendingPathComponent(duplicateStructurePresentedFileName)
    }

    static var duplicateStructureActionURL: URL? {
        rootDirectory?.appendingPathComponent(duplicateStructureActionFileName)
    }

    static var duplicateStructureDismissedURL: URL? {
        rootDirectory?.appendingPathComponent(duplicateStructureDismissedFileName)
    }

    static var appearanceSettingsCommandURL: URL? {
        rootDirectory?.appendingPathComponent(appearanceSettingsCommandFileName)
    }

    static var appearanceSettingsAcknowledgementURL: URL? {
        rootDirectory?.appendingPathComponent(appearanceSettingsAcknowledgementFileName)
    }

    static var paneStateRequestURL: URL? {
        rootDirectory?.appendingPathComponent(paneStateRequestFileName)
    }

    static var paneStateResponseURL: URL? {
        rootDirectory?.appendingPathComponent(paneStateResponseFileName)
    }

    static var openedItemsHistoryURL: URL? {
        rootDirectory?.appendingPathComponent(openedItemsHistoryFileName)
    }

    static var remoteMutationCommandURL: URL? {
        rootDirectory?.appendingPathComponent(remoteMutationCommandFileName)
    }

    static var keychainLifecycleResultURL: URL? {
        rootDirectory?.appendingPathComponent(keychainLifecycleResultFileName)
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

    static func currentRemoteFailureCommand() -> RemoteFailureCommand? {
        guard let url = remoteFailureCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(RemoteFailureCommand.self, from: data)
    }

    static func currentUndoMenuTitleRequest() -> UndoMenuTitleRequest? {
        guard let url = undoMenuTitleRequestURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(UndoMenuTitleRequest.self, from: data)
    }

    static func currentDuplicateStructureShowRequest() -> DuplicateStructureShowRequest? {
        guard let url = duplicateStructureShowRequestURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(DuplicateStructureShowRequest.self, from: data)
    }

    static func currentDuplicateStructureAction() -> DuplicateStructureAction? {
        guard let url = duplicateStructureActionURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(DuplicateStructureAction.self, from: data)
    }

    static func currentAppearanceSettingsCommand() -> AppearanceSettingsCommand? {
        guard let url = appearanceSettingsCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(AppearanceSettingsCommand.self, from: data)
    }

    static func currentPaneStateRequest() -> PaneStateRequest? {
        guard let url = paneStateRequestURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(PaneStateRequest.self, from: data)
    }

    static func currentRemoteMutationCommand() -> RemoteMutationCommand? {
        guard let url = remoteMutationCommandURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(RemoteMutationCommand.self, from: data)
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
              let data = try? JSONEncoder().encode(NetworkShareDismissalAck(id: id)) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func acknowledgeRemoteFailureCommand(id: String, handled: Bool) {
        guard let url = remoteFailureAcknowledgementURL,
              let data = try? JSONEncoder().encode(RemoteFailureAcknowledgement(id: id, handled: handled)) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func writeUndoMenuTitleResponse(id: String, title: String) {
        guard let url = undoMenuTitleResponseURL,
              let data = try? JSONEncoder().encode(UndoMenuTitleResponse(id: id, title: title)) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func writeDuplicateStructurePresented(id: String, sourceName: String, folderName: String) {
        guard let url = duplicateStructurePresentedURL,
              let data = try? JSONEncoder().encode(DuplicateStructurePresentation(
                id: id,
                sourceName: sourceName,
                folderName: folderName
              )) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func writeDuplicateStructureDismissed(id: String) {
        guard let url = duplicateStructureDismissedURL,
              let data = try? JSONEncoder().encode(DuplicateStructureDismissal(id: id)) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func acknowledgeAppearanceSettingsCommand(
        id: String,
        applied: Bool,
        checkedTextCount: Int = 0,
        failure: String? = nil
    ) {
        guard let url = appearanceSettingsAcknowledgementURL,
              let data = try? JSONEncoder().encode(AppearanceSettingsAcknowledgement(
                id: id,
                applied: applied,
                checkedTextCount: checkedTextCount,
                failure: failure
              )) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func writePaneStateResponse(_ response: PaneStateResponse) {
        guard let url = paneStateResponseURL,
              let data = try? JSONEncoder().encode(response) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func writeKeychainLifecycleResult(success: Bool, failure: String? = nil) {
        guard let url = keychainLifecycleResultURL,
              let data = try? JSONEncoder().encode(KeychainLifecycleResult(
                success: success,
                failure: failure
              )) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func recordOpenedItem(_ name: String) {
        guard recordsOpenedItems, let url = openedItemsHistoryURL else { return }
        var names: [String] = []
        if let data = try? Data(contentsOf: url) {
            names = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        names.append(name)
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
