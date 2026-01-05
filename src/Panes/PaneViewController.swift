import AppKit

final class PaneViewController: NSViewController {
    private let tabBar = PaneTabBar()
    private let tabContainer = NSView()

    private(set) var tabs: [PaneTab] = []
    private(set) var selectedTabIndex: Int = 0

    private var isActive: Bool = false

    var selectedTab: PaneTab? {
        guard selectedTabIndex >= 0 && selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupTabBar()
        setupTabContainer()
        setupConstraints()

        // Create initial tab at home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        createTab(at: homeDir, select: true)
    }

    private func setupTabBar() {
        tabBar.delegate = self
        tabBar.paneViewController = self
        view.addSubview(tabBar)
    }

    private func setupTabContainer() {
        tabContainer.wantsLayer = true
        view.addSubview(tabContainer)
    }

    private func setupConstraints() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Tab bar at top, 32px height
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            // Tab container fills remaining space
            tabContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Tab Management

    @discardableResult
    func createTab(at url: URL, select: Bool = true) -> PaneTab {
        let tab = PaneTab(directory: url)
        tab.fileListViewController.navigationDelegate = self

        tabs.append(tab)

        // Add file list view to container (hidden initially unless selected)
        addChild(tab.fileListViewController)
        tabContainer.addSubview(tab.fileListViewController.view)
        tab.fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.fileListViewController.view.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            tab.fileListViewController.view.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tab.fileListViewController.view.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            tab.fileListViewController.view.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        ])

        if select {
            selectTab(at: tabs.count - 1)
        } else {
            tab.fileListViewController.view.isHidden = true
        }

        reloadTabBar()
        return tab
    }

    func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        // Minimum one tab rule
        if tabs.count == 1 {
            // Replace with new tab at home directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let oldTab = tabs[0]

            // Remove old tab's view
            oldTab.fileListViewController.view.removeFromSuperview()
            oldTab.fileListViewController.removeFromParent()

            tabs.removeAll()
            selectedTabIndex = 0

            createTab(at: homeDir, select: true)
            return
        }

        let tab = tabs[index]

        // Remove view
        tab.fileListViewController.view.removeFromSuperview()
        tab.fileListViewController.removeFromParent()

        tabs.remove(at: index)

        // Adjust selection
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = tabs.count - 1
        } else if selectedTabIndex > index {
            selectedTabIndex -= 1
        } else if selectedTabIndex == index {
            // Select right neighbor if exists, else left
            selectedTabIndex = min(index, tabs.count - 1)
        }

        // Show the now-selected tab
        if let selected = selectedTab {
            selected.fileListViewController.view.isHidden = false
        }

        reloadTabBar()
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        guard index != selectedTabIndex || tabs.count == 1 else { return }

        // Hide current tab's view
        if selectedTabIndex < tabs.count {
            tabs[selectedTabIndex].fileListViewController.view.isHidden = true
        }

        selectedTabIndex = index

        // Show new tab's view
        let tab = tabs[selectedTabIndex]
        tab.fileListViewController.view.isHidden = false

        tabBar.updateSelectedIndex(index)

        // Make first responder if this pane is active
        if isActive {
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }
    }

    func selectNextTab() {
        let nextIndex = (selectedTabIndex + 1) % tabs.count
        selectTab(at: nextIndex)
    }

    func selectPreviousTab() {
        let prevIndex = selectedTabIndex == 0 ? tabs.count - 1 : selectedTabIndex - 1
        selectTab(at: prevIndex)
    }

    private func reloadTabBar() {
        tabBar.reloadTabs(tabs, selectedIndex: selectedTabIndex)
    }

    // MARK: - Navigation (delegate to selected tab)

    func navigate(to url: URL) {
        selectedTab?.navigate(to: url)
        reloadTabBar() // Title may have changed
    }

    func goBack() {
        selectedTab?.goBack()
        reloadTabBar()
    }

    func goForward() {
        selectedTab?.goForward()
        reloadTabBar()
    }

    func goUp() {
        selectedTab?.goUp()
        reloadTabBar()
    }

    // MARK: - Active State

    func setActive(_ active: Bool) {
        isActive = active
        updateBackgroundTint()

        if active, let tab = selectedTab {
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }
    }

    private func updateBackgroundTint() {
        guard let layer = tabContainer.layer else { return }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        if isActive {
            if isDark {
                layer.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
            } else {
                layer.backgroundColor = NSColor(white: 0.94, alpha: 1.0).cgColor
            }
        } else {
            if isDark {
                layer.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
            } else {
                layer.backgroundColor = NSColor(white: 0.98, alpha: 1.0).cgColor
            }
        }
    }

    // MARK: - Tab Transfer (for cross-pane drag)

    func removeTab(_ tab: PaneTab) -> PaneTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }

        // Can't remove last tab
        if tabs.count == 1 {
            return nil
        }

        let removedTab = tabs[index]

        // Remove view
        removedTab.fileListViewController.view.removeFromSuperview()
        removedTab.fileListViewController.removeFromParent()

        tabs.remove(at: index)

        // Adjust selection
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = tabs.count - 1
        } else if selectedTabIndex >= index {
            selectedTabIndex = max(0, selectedTabIndex - 1)
        }

        if let selected = selectedTab {
            selected.fileListViewController.view.isHidden = false
        }

        reloadTabBar()
        return removedTab
    }

    func insertTab(_ tab: PaneTab, at index: Int) {
        let insertIndex = min(index, tabs.count)

        tab.fileListViewController.navigationDelegate = self

        tabs.insert(tab, at: insertIndex)

        // Add view
        addChild(tab.fileListViewController)
        tabContainer.addSubview(tab.fileListViewController.view)
        tab.fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.fileListViewController.view.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            tab.fileListViewController.view.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tab.fileListViewController.view.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            tab.fileListViewController.view.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        ])

        selectTab(at: insertIndex)
        reloadTabBar()
    }
}

// MARK: - PaneTabBarDelegate

extension PaneViewController: PaneTabBarDelegate {
    func tabBarDidSelectTab(at index: Int) {
        selectTab(at: index)
    }

    func tabBarDidRequestCloseTab(at index: Int) {
        closeTab(at: index)
    }

    func tabBarDidRequestNewTab() {
        let currentDir = selectedTab?.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        createTab(at: currentDir, select: true)
    }

    func tabBarDidReorderTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0 && sourceIndex < tabs.count else { return }
        guard destinationIndex >= 0 && destinationIndex <= tabs.count else { return }

        let tab = tabs.remove(at: sourceIndex)
        let adjustedDestination = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        tabs.insert(tab, at: adjustedDestination)

        // Update selected index if needed
        if selectedTabIndex == sourceIndex {
            selectedTabIndex = adjustedDestination
        } else if sourceIndex < selectedTabIndex && adjustedDestination >= selectedTabIndex {
            selectedTabIndex -= 1
        } else if sourceIndex > selectedTabIndex && adjustedDestination <= selectedTabIndex {
            selectedTabIndex += 1
        }

        reloadTabBar()
    }

    func tabBarDidReceiveDroppedTab(_ tab: PaneTab, at index: Int) {
        insertTab(tab, at: index)
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
        if let splitVC = parent as? MainSplitViewController {
            splitVC.switchToOtherPane()
        }
    }

    func fileListDidBecomeActive() {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.setActivePaneFromChild(self)
        }
    }

    func fileListDidRequestOpenInNewTab(url: URL) {
        createTab(at: url, select: true)
    }
}
