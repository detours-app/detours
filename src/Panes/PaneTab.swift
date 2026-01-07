import AppKit

/// Represents a single tab within a pane.
/// Each tab maintains its own directory and navigation history.
@MainActor
final class PaneTab {
    let id: UUID
    private(set) var currentDirectory: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    /// Lazily created file list view controller for this tab
    lazy var fileListViewController: FileListViewController = {
        let vc = FileListViewController()
        vc.loadDirectory(currentDirectory)
        return vc
    }()

    /// Directory name for tab title
    var title: String {
        currentDirectory.lastPathComponent
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

    init(directory: URL) {
        self.id = UUID()
        self.currentDirectory = Self.normalizeDirectoryURL(directory)
    }

    // MARK: - Navigation

    /// Navigate to a directory, optionally adding current to history
    func navigate(to url: URL, addToHistory: Bool = true, skipContainerResolution: Bool = false) {
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

        if addToHistory && currentDirectory != normalized {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
        }

        currentDirectory = normalized
        fileListViewController.loadDirectory(currentDirectory)
    }

    /// Go back in history. Returns false if can't go back.
    @discardableResult
    func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        forwardStack.append(currentDirectory)
        currentDirectory = previous
        fileListViewController.loadDirectory(currentDirectory)
        return true
    }

    /// Go forward in history. Returns false if can't go forward.
    @discardableResult
    func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(currentDirectory)
        currentDirectory = next
        fileListViewController.loadDirectory(currentDirectory)
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

        var parent = Self.normalizeDirectoryURL(currentDirectory.deletingLastPathComponent())
        guard parent != currentDirectory else { return false }

        // If we're in an iCloud container's Documents folder, skip the container and go to Mobile Documents
        if Self.isICloudContainerDocuments(currentDirectory) {
            parent = Self.normalizeDirectoryURL(parent.deletingLastPathComponent())
        }

        navigate(to: parent, skipContainerResolution: true)
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
}
