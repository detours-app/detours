import AppKit

/// Represents a single tab within a pane.
/// Each tab maintains its own directory and navigation history.
@MainActor
final class PaneTab {
    /// Navigation history entry storing directory and selection to restore
    private struct HistoryEntry {
        let directory: URL
        let iCloudListingMode: ICloudListingMode
        let selectionToRestore: URL?  // Item to select when returning to this directory
    }

    let id: UUID
    private(set) var currentDirectory: URL
    private(set) var iCloudListingMode: ICloudListingMode
    private var backStack: [HistoryEntry] = []
    private var forwardStack: [HistoryEntry] = []

    /// Pending restore state for deferred loading
    private(set) var pendingExpansions: Set<URL>?
    private(set) var pendingSelections: [URL]?

    /// Lazily created file list view controller for this tab
    /// Note: Does NOT load directory on creation - caller must call loadDirectory or ensureLoaded
    lazy var fileListViewController: FileListViewController = {
        let vc = FileListViewController()
        vc.currentDirectory = currentDirectory
        vc.currentICloudListingMode = iCloudListingMode
        return vc
    }()

    /// Directory name for tab title
    var title: String {
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

    init(directory: URL, iCloudListingMode: ICloudListingMode = .normal) {
        self.id = UUID()
        self.currentDirectory = Self.normalizeDirectoryURL(directory)
        self.iCloudListingMode = Self.resolveListingMode(for: self.currentDirectory, requested: iCloudListingMode)
    }

    // MARK: - Navigation

    /// Navigate to a directory, optionally adding current to history
    func navigate(to url: URL, iCloudListingMode listingMode: ICloudListingMode = .normal, addToHistory: Bool = true, skipContainerResolution: Bool = false) {
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

        if addToHistory && (currentDirectory != normalized || iCloudListingMode != resolvedMode) {
            // Store current directory with the folder we're navigating into as the selection to restore
            let entry = HistoryEntry(directory: currentDirectory, iCloudListingMode: iCloudListingMode, selectionToRestore: normalized)
            backStack.append(entry)
            forwardStack.removeAll()
        }

        currentDirectory = normalized
        iCloudListingMode = resolvedMode
        fileListViewController.loadDirectory(currentDirectory, iCloudListingMode: resolvedMode)
    }

    /// Go back in history. Returns false if can't go back.
    @discardableResult
    func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        // When going back, store current directory; when user goes forward again, select where they came from
        let entry = HistoryEntry(directory: currentDirectory, iCloudListingMode: iCloudListingMode, selectionToRestore: previous.selectionToRestore)
        forwardStack.append(entry)
        currentDirectory = previous.directory
        iCloudListingMode = previous.iCloudListingMode
        fileListViewController.loadDirectory(currentDirectory, selectingItem: previous.selectionToRestore, iCloudListingMode: previous.iCloudListingMode)
        return true
    }

    /// Go forward in history. Returns false if can't go forward.
    @discardableResult
    func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        // When going forward, store current directory with the target as selection to restore on back
        let entry = HistoryEntry(directory: currentDirectory, iCloudListingMode: iCloudListingMode, selectionToRestore: next.directory)
        backStack.append(entry)
        currentDirectory = next.directory
        iCloudListingMode = next.iCloudListingMode
        fileListViewController.loadDirectory(currentDirectory, selectingItem: next.selectionToRestore, iCloudListingMode: next.iCloudListingMode)
        return true
    }

    func refresh() {
        fileListViewController.refresh()
    }

    /// Go to parent directory. Returns false if already at root.
    @discardableResult
    func goUp() -> Bool {
        // Don't go up from Mobile Documents (treat it as iCloud root)
        if Self.isMobileDocuments(currentDirectory) {
            return false
        }

        let currentDir = currentDirectory
        var parent = Self.normalizeDirectoryURL(currentDirectory.deletingLastPathComponent())
        guard parent != currentDirectory else { return false }

        // If we're in an iCloud container's Documents folder, skip the container and go to Mobile Documents
        if Self.isICloudContainerDocuments(currentDirectory) {
            parent = Self.normalizeDirectoryURL(parent.deletingLastPathComponent())
        }

        // Navigate to parent, selecting the folder we just left
        let entry = HistoryEntry(directory: currentDir, iCloudListingMode: iCloudListingMode, selectionToRestore: currentDir)
        backStack.append(entry)
        forwardStack.removeAll()
        currentDirectory = parent
        iCloudListingMode = .normal
        fileListViewController.loadDirectory(parent, selectingItem: currentDir, iCloudListingMode: iCloudListingMode)
        return true
    }

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    private static func normalizeDirectoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    private static func resolveListingMode(for url: URL, requested: ICloudListingMode) -> ICloudListingMode {
        if requested == .sharedTopLevel, isCloudDocs(url) {
            return .sharedTopLevel
        }
        return .normal
    }

    private static func isCloudDocs(_ url: URL) -> Bool {
        url.lastPathComponent == "com~apple~CloudDocs"
    }

    private static func cloudDocsDisplayName(for url: URL) -> String {
        if let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localizedName.isEmpty {
            return localizedName
        }
        return "iCloud Drive"
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
