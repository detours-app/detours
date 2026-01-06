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
    func navigate(to url: URL, addToHistory: Bool = true) {
        let normalized = Self.normalizeDirectoryURL(url)
        // Check if it's actually a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // It's a file, open it with default app
            NSWorkspace.shared.open(normalized)
            return
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
        fileListViewController.loadDirectory(currentDirectory)
    }

    /// Go to parent directory. Returns false if already at root.
    @discardableResult
    func goUp() -> Bool {
        let parent = Self.normalizeDirectoryURL(currentDirectory.deletingLastPathComponent())
        guard parent != currentDirectory else { return false }
        navigate(to: parent)
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
}
