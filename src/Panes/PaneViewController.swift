import AppKit

final class PaneViewController: NSViewController {
    let fileListViewController = FileListViewController()

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var currentDirectory: URL

    private var isActive: Bool = false

    init() {
        self.currentDirectory = FileManager.default.homeDirectoryForCurrentUser
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Add file list as child
        addChild(fileListViewController)
        view.addSubview(fileListViewController.view)

        // Set delegate for navigation
        fileListViewController.navigationDelegate = self

        // Load initial directory
        navigate(to: currentDirectory, addToHistory: false)

        setupConstraints()
    }

    private func setupConstraints() {
        fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            fileListViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            fileListViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fileListViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fileListViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Navigation

    func navigate(to url: URL, addToHistory: Bool = true) {
        guard url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            // It's a file, open it
            NSWorkspace.shared.open(url)
            return
        }

        if addToHistory && currentDirectory != url {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
        }

        currentDirectory = url
        fileListViewController.loadDirectory(url)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentDirectory)
        currentDirectory = previous
        fileListViewController.loadDirectory(currentDirectory)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentDirectory)
        currentDirectory = next
        fileListViewController.loadDirectory(currentDirectory)
    }

    func goUp() {
        let parent = currentDirectory.deletingLastPathComponent()
        guard parent != currentDirectory else { return }
        navigate(to: parent)
    }

    // MARK: - Active State

    func setActive(_ active: Bool) {
        isActive = active
        updateBackgroundTint()

        if active {
            view.window?.makeFirstResponder(fileListViewController.tableView)
        }
    }

    private func updateBackgroundTint() {
        guard let layer = view.layer else { return }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        if isActive {
            // Active pane: darker/more prominent
            if isDark {
                layer.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
            } else {
                layer.backgroundColor = NSColor(white: 0.94, alpha: 1.0).cgColor
            }
        } else {
            // Inactive pane: lighter/washed out
            if isDark {
                layer.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
            } else {
                layer.backgroundColor = NSColor(white: 0.98, alpha: 1.0).cgColor
            }
        }
    }
}

// MARK: - FileListNavigationDelegate

extension PaneViewController: FileListNavigationDelegate {
    func fileListDidRequestNavigation(to url: URL) {
        navigate(to: url)
    }

    func fileListDidRequestParentNavigation() {
        goUp()
    }

    func fileListDidRequestSwitchPane() {
        // Find the split view controller and ask it to switch
        if let splitVC = parent as? MainSplitViewController {
            splitVC.switchToOtherPane()
        }
    }

    func fileListDidBecomeActive() {
        // Notify split view controller that this pane should be active
        if let splitVC = parent as? MainSplitViewController {
            splitVC.setActivePaneFromChild(self)
        }
    }
}
