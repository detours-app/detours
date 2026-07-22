import AppKit

/// Represents a single tab within a pane.
/// Each tab maintains its own directory and navigation history.
@MainActor
final class PaneTab {
    /// Navigation history entry storing directory and selection to restore
    private struct RemoteHistoryDestination {
        let host: RemoteHost
        let path: String
        let provider: (any FileProvider)?
    }

    private struct HistoryEntry {
        let directory: URL
        let iCloudListingMode: ICloudListingMode
        let sharedNavigationRootURL: URL?
        let selectionToRestore: URL?  // Item to select when returning to this directory
        let remoteDestination: RemoteHistoryDestination?
    }

    let id: UUID
    private(set) var currentDirectory: URL
    private(set) var iCloudListingMode: ICloudListingMode
    private(set) var sharedNavigationRootURL: URL?
    private var backStack: [HistoryEntry] = []
    private var forwardStack: [HistoryEntry] = []

    /// Pending restore state for deferred loading
    private(set) var pendingExpansions: Set<URL>?
    private(set) var pendingSelections: [URL]?

    /// Tab title for remote tabs, set by the pane on remote navigation.
    /// `currentDirectory` is a local URL and is not meaningful for remote tabs.
    var remoteTitle: String?
    var remoteFullPath: String?

    /// Created on first access for this tab.
    /// Note: Does NOT load directory on creation - caller must call loadDirectory or ensureLoaded
    private var _fileListViewController: FileListViewController?
    var fileListViewController: FileListViewController {
        if let existing = _fileListViewController {
            return existing
        }
        let vc = FileListViewController()
        vc.currentDirectory = currentDirectory
        vc.currentICloudListingMode = iCloudListingMode
        _fileListViewController = vc
        return vc
    }

    /// The view controller only if it has already been created, so callers can
    /// inspect loaded tabs without forcing every tab's controller into existence.
    var fileListViewControllerIfLoaded: FileListViewController? {
        _fileListViewController
    }

    /// Directory name for tab title
    var title: String {
        if let remoteTitle {
            return remoteTitle
        }
        let name = currentDirectory.lastPathComponent
        switch name {
        case "com~apple~CloudDocs":
            if iCloudListingMode == .sharedTopLevel {
                return "Shared"
            }
            return Self.cloudDocsDisplayName(for: currentDirectory)
        case "Mobile Documents":
            return "iCloud Drive"
        default:
            // Check for iCloud app container names (e.g., "com~apple~Automator")
            if name.hasPrefix("com~apple~") || name.hasPrefix("com~") {
                // Try to get localized name from file system
                if let localizedName = try? currentDirectory.resourceValues(forKeys: [.localizedNameKey]).localizedName {
                    return localizedName
                }
            }
            return name
        }
    }

    /// Full path for tooltip, with ~ for home directory
    var fullPath: String {
        let path = currentDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var displayPath: String {
        remoteFullPath ?? fullPath
    }

    init(directory: URL, iCloudListingMode: ICloudListingMode = .normal) {
        self.id = UUID()
        self.currentDirectory = Self.normalizeDirectoryURL(directory)
        self.iCloudListingMode = Self.resolveListingMode(for: self.currentDirectory, requested: iCloudListingMode)
        if self.iCloudListingMode == .sharedTopLevel,
           !Self.isCloudDocs(self.currentDirectory),
           !Self.isMobileDocuments(self.currentDirectory) {
            self.sharedNavigationRootURL = self.currentDirectory
        } else {
            self.sharedNavigationRootURL = nil
        }
    }

    // MARK: - Navigation

    /// Navigate to a directory, optionally adding current to history
    func navigate(to url: URL, iCloudListingMode listingMode: ICloudListingMode = .normal, addToHistory: Bool = true, skipContainerResolution: Bool = false, selectingItem itemToSelect: URL? = nil) {
        let previousDirectory = currentDirectory
        let previousMode = iCloudListingMode
        let previousSharedRoot = sharedNavigationRootURL
        var normalized = Self.normalizeDirectoryURL(url)
        // Check if it's actually a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // It's a file, open it with default app
            NSWorkspace.shared.open(normalized)
            return
        }

        // For iCloud app containers, skip directly to Documents subfolder
        if !skipContainerResolution {
            normalized = Self.resolveICloudContainer(normalized)
        }

        let resolvedMode = Self.resolveListingMode(for: normalized, requested: listingMode)
        let resolvedSharedRoot = Self.resolveSharedNavigationRoot(
            target: normalized,
            mode: resolvedMode,
            previousDirectory: previousDirectory,
            previousMode: previousMode,
            previousRoot: previousSharedRoot
        )

        let isRemote = fileListViewControllerIfLoaded?.currentRemoteLocation != nil
        if addToHistory && (isRemote || currentDirectory != normalized || iCloudListingMode != resolvedMode) {
            // Store current directory with the folder we're navigating into as the selection to restore
            backStack.append(
                makeHistoryEntry(selectionToRestore: isRemote ? nil : normalized)
            )
            forwardStack.removeAll()
        }

        remoteTitle = nil
        remoteFullPath = nil
        currentDirectory = normalized
        iCloudListingMode = resolvedMode
        sharedNavigationRootURL = resolvedSharedRoot
        fileListViewController.loadDirectory(currentDirectory, selectingItem: itemToSelect, iCloudListingMode: resolvedMode)
    }

    func navigateRemote(
        host: RemoteHost,
        path: String,
        provider: any FileProvider,
        addToHistory: Bool = true
    ) {
        setRemoteDestination(
            RemoteHistoryDestination(host: host, path: path, provider: provider),
            addToHistory: addToHistory
        )
    }

    func showPendingRemoteHost(
        _ host: RemoteHost,
        path: String,
        addToHistory: Bool = true
    ) {
        setRemoteDestination(
            RemoteHistoryDestination(host: host, path: path, provider: nil),
            addToHistory: addToHistory
        )
    }

    /// Go back in history. Returns false if can't go back.
    @discardableResult
    func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        // When going back, store current directory; when user goes forward again, select where they came from
        forwardStack.append(
            makeHistoryEntry(
                selectionToRestore: previous.remoteDestination == nil
                    ? previous.selectionToRestore
                    : nil
            )
        )
        applyHistoryEntry(previous)
        return true
    }

    /// Go forward in history. Returns false if can't go forward.
    @discardableResult
    func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        // When going forward, store current directory with the target as selection to restore on back
        backStack.append(
            makeHistoryEntry(
                selectionToRestore: next.remoteDestination == nil ? next.directory : nil
            )
        )
        applyHistoryEntry(next)
        return true
    }

    func refresh() {
        fileListViewController.refresh()
    }

    /// Go to parent directory. Returns false if already at root.
    @discardableResult
    func goUp() -> Bool {
        guard fileListViewControllerIfLoaded?.currentRemoteLocation == nil else { return false }
        if iCloudListingMode == .sharedTopLevel {
            return goUpInSharedContext()
        }

        // Don't go up from Mobile Documents (treat it as iCloud root)
        if Self.isMobileDocuments(currentDirectory) { return false }

        let currentDir = currentDirectory
        var parent = Self.normalizeDirectoryURL(currentDirectory.deletingLastPathComponent())
        guard parent != currentDirectory else { return false }

        // If we're in an iCloud container's Documents folder, skip the container and go to Mobile Documents
        if Self.isICloudContainerDocuments(currentDirectory) {
            parent = Self.normalizeDirectoryURL(parent.deletingLastPathComponent())
        }

        // Navigate to parent, selecting the folder we just left
        let entry = HistoryEntry(
            directory: currentDir,
            iCloudListingMode: iCloudListingMode,
            sharedNavigationRootURL: sharedNavigationRootURL,
            selectionToRestore: currentDir,
            remoteDestination: nil
        )
        backStack.append(entry)
        forwardStack.removeAll()
        currentDirectory = parent
        iCloudListingMode = .normal
        sharedNavigationRootURL = nil
        fileListViewController.loadDirectory(parent, selectingItem: currentDir, iCloudListingMode: iCloudListingMode)
        return true
    }

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    private func makeHistoryEntry(selectionToRestore: URL?) -> HistoryEntry {
        let remoteDestination: RemoteHistoryDestination?
        if let controller = fileListViewControllerIfLoaded,
           let host = controller.currentRemoteHost,
           case .remote(_, let path)? = controller.currentRemoteLocation {
            remoteDestination = RemoteHistoryDestination(
                host: host,
                path: path,
                provider: controller.currentRemoteProvider
            )
        } else {
            remoteDestination = nil
        }
        return HistoryEntry(
            directory: currentDirectory,
            iCloudListingMode: iCloudListingMode,
            sharedNavigationRootURL: sharedNavigationRootURL,
            selectionToRestore: selectionToRestore,
            remoteDestination: remoteDestination
        )
    }

    private func setRemoteDestination(
        _ destination: RemoteHistoryDestination,
        addToHistory: Bool
    ) {
        let currentRemoteLocation = fileListViewControllerIfLoaded?.currentRemoteLocation
        let isSameRemoteDestination: Bool
        if case .remote(let hostID, let path)? = currentRemoteLocation {
            isSameRemoteDestination = hostID == destination.host.id && path == destination.path
        } else {
            isSameRemoteDestination = false
        }
        if addToHistory && !isSameRemoteDestination {
            backStack.append(makeHistoryEntry(selectionToRestore: nil))
            forwardStack.removeAll()
        }
        applyRemoteDestination(destination)
    }

    private func applyHistoryEntry(_ entry: HistoryEntry) {
        currentDirectory = entry.directory
        iCloudListingMode = entry.iCloudListingMode
        sharedNavigationRootURL = entry.sharedNavigationRootURL
        if let remoteDestination = entry.remoteDestination {
            applyRemoteDestination(remoteDestination)
            return
        }
        remoteTitle = nil
        remoteFullPath = nil
        fileListViewController.loadDirectory(
            currentDirectory,
            selectingItem: entry.selectionToRestore,
            iCloudListingMode: entry.iCloudListingMode
        )
    }

    private func applyRemoteDestination(_ destination: RemoteHistoryDestination) {
        remoteTitle = destination.path.split(separator: "/").last.map(String.init)
            ?? destination.host.displayName
        let normalizedPath = destination.path.hasPrefix("/")
            ? destination.path
            : "/" + destination.path
        remoteFullPath = "\(destination.host.displayName):\(normalizedPath)"
        if let provider = destination.provider {
            fileListViewController.loadRemoteDirectory(
                host: destination.host,
                path: destination.path,
                provider: provider
            )
        } else {
            fileListViewController.showPendingRemoteReconnect(
                host: destination.host,
                path: destination.path
            )
        }
    }

    private static func normalizeDirectoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    private static func resolveListingMode(for url: URL, requested: ICloudListingMode) -> ICloudListingMode {
        requested == .sharedTopLevel ? .sharedTopLevel : .normal
    }

    private static func isCloudDocs(_ url: URL) -> Bool {
        url.lastPathComponent == "com~apple~CloudDocs"
    }

    private static func cloudDocsURL() -> URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: cloudDocs.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return cloudDocs
        }
        return nil
    }

    private static func cloudDocsAncestor(of url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard let index = components.firstIndex(of: "com~apple~CloudDocs") else { return nil }
        let prefix = components.prefix(index + 1)
        return URL(fileURLWithPath: NSString.path(withComponents: Array(prefix))).standardizedFileURL
    }

    private static func cloudDocsDisplayName(for url: URL) -> String {
        if let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localizedName.isEmpty {
            return localizedName
        }
        return "iCloud Drive"
    }

    private static func isWithin(_ child: URL, root: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static func resolveSharedNavigationRoot(
        target: URL,
        mode: ICloudListingMode,
        previousDirectory: URL,
        previousMode: ICloudListingMode,
        previousRoot: URL?
    ) -> URL? {
        guard mode == .sharedTopLevel else { return nil }
        if isCloudDocs(target) || isMobileDocuments(target) {
            return nil
        }

        if previousMode != .sharedTopLevel || isCloudDocs(previousDirectory) || isMobileDocuments(previousDirectory) {
            return target
        }

        if let previousRoot, isWithin(target, root: previousRoot) {
            return previousRoot.standardizedFileURL
        }
        return target
    }

    private func goUpInSharedContext() -> Bool {
        if Self.isCloudDocs(currentDirectory) || Self.isMobileDocuments(currentDirectory) {
            return false
        }

        let currentDir = currentDirectory.standardizedFileURL
        let root = sharedNavigationRootURL?.standardizedFileURL ?? currentDir
        let sharedListURL = Self.cloudDocsAncestor(of: currentDir) ??
            Self.cloudDocsAncestor(of: root) ??
            Self.cloudDocsURL()
        let entry = HistoryEntry(
            directory: currentDir,
            iCloudListingMode: iCloudListingMode,
            sharedNavigationRootURL: sharedNavigationRootURL,
            selectionToRestore: currentDir,
            remoteDestination: nil
        )
        backStack.append(entry)
        forwardStack.removeAll()

        if currentDir == root || !Self.isWithin(currentDir, root: root) {
            guard let cloudDocs = sharedListURL else { return false }
            currentDirectory = cloudDocs
            iCloudListingMode = .sharedTopLevel
            sharedNavigationRootURL = nil
            fileListViewController.loadDirectory(cloudDocs, selectingItem: currentDir, iCloudListingMode: .sharedTopLevel)
            return true
        }

        let parent = currentDir.deletingLastPathComponent().standardizedFileURL
        if parent == root.deletingLastPathComponent().standardizedFileURL || !Self.isWithin(parent, root: root) {
            guard let cloudDocs = sharedListURL else { return false }
            currentDirectory = cloudDocs
            iCloudListingMode = .sharedTopLevel
            sharedNavigationRootURL = nil
            fileListViewController.loadDirectory(cloudDocs, selectingItem: root, iCloudListingMode: .sharedTopLevel)
            return true
        }

        currentDirectory = parent
        iCloudListingMode = .sharedTopLevel
        sharedNavigationRootURL = root
        fileListViewController.loadDirectory(parent, selectingItem: currentDir, iCloudListingMode: .sharedTopLevel)
        return true
    }

    /// For iCloud app containers (inside Mobile Documents), skip to Documents subfolder
    private static func resolveICloudContainer(_ url: URL) -> URL {
        let path = url.path
        let mobileDocsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents").path

        // Check if we're inside Mobile Documents but not in com~apple~CloudDocs (user files)
        guard path.hasPrefix(mobileDocsPath),
              !path.contains("com~apple~CloudDocs") else {
            return url
        }

        // Check if this is a direct child of Mobile Documents (an app container)
        let relativePath = String(path.dropFirst(mobileDocsPath.count + 1))
        guard !relativePath.contains("/") else {
            return url  // Already inside a container
        }

        // Check if Documents subfolder exists
        let documentsURL = url.appendingPathComponent("Documents")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: documentsURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return documentsURL
        }

        return url
    }

    /// Check if URL is inside an iCloud container's Documents folder
    private static func isICloudContainerDocuments(_ url: URL) -> Bool {
        let path = url.path
        let mobileDocsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents").path

        guard path.hasPrefix(mobileDocsPath),
              !path.contains("com~apple~CloudDocs") else {
            return false
        }

        // Pattern: Mobile Documents/<container>/Documents[/...]
        let relativePath = String(path.dropFirst(mobileDocsPath.count + 1))
        let components = relativePath.split(separator: "/")
        return components.count >= 2 && components[1] == "Documents"
    }

    /// Check if URL is the Mobile Documents folder (iCloud root)
    private static func isMobileDocuments(_ url: URL) -> Bool {
        let mobileDocsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents").path
        return url.path == mobileDocsPath
    }

    /// Store state to restore when tab is loaded on-demand
    func storePendingRestore(expansions: Set<URL>?, selections: [URL]?) {
        pendingExpansions = expansions
        pendingSelections = selections
    }

    /// Clear pending restore state (called after applying)
    func clearPendingRestore() {
        pendingExpansions = nil
        pendingSelections = nil
    }
}

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
