import AppKit

// MARK: - Pane View Controller

/// Remote host and path a tab was viewing, persisted across relaunches.
struct RemoteTabSessionTarget: Equatable {
    let hostID: UUID
    let path: String

    /// Encodes one entry per tab; local tabs become empty dictionaries.
    static func encode(_ targets: [RemoteTabSessionTarget?]) -> [[String: String]] {
        targets.map { target in
            guard let target else { return [:] }
            return ["hostID": target.hostID.uuidString, "path": target.path]
        }
    }

    /// Decodes saved entries; anything malformed or misaligned yields all-local tabs.
    static func decode(_ data: Any?, count: Int) -> [RemoteTabSessionTarget?] {
        guard let raw = data as? [[String: String]], raw.count == count else {
            return Array(repeating: nil, count: count)
        }
        return raw.map { entry in
            guard let hostIDString = entry["hostID"],
                  let hostID = UUID(uuidString: hostIDString),
                  let path = entry["path"] else {
                return nil
            }
            return RemoteTabSessionTarget(hostID: hostID, path: path)
        }
    }
}

final class PaneViewController: NSViewController {
    let tabBar = PaneTabBar()
    let homeButton = NSButton()
    let iCloudButton = NSButton()
    let pathControl = DroppablePathControl()
    let reconnectBanner = NSView()
    let reconnectBannerLabel = NSTextField(labelWithString: "")
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let reconnectDismissButton = NSButton(title: "", target: nil, action: nil)
    let tabContainer = NSView()
    let statusBar = StatusBarView()
    var detailPopover: OperationDetailPopover?
    var operationStatusBarForceShown = false

    var tabs: [PaneTab] = []
    var selectedTabIndex: Int = 0

    var isActive: Bool = false
    var pathItemURLs: [URL?] = []  // URLs for each path item (nil for ellipsis)
    var statusBarBottomConstraint: NSLayoutConstraint?
    var tabContainerBottomConstraint: NSLayoutConstraint?
    var pathControlLeadingToICloudConstraint: NSLayoutConstraint?
    var pathControlLeadingToViewConstraint: NSLayoutConstraint?
    private var pathControlTrailingConstraint: NSLayoutConstraint?
    var reconnectBannerHeightConstraint: NSLayoutConstraint?
    var remoteBreadcrumbHostsByTabID: [UUID: RemoteHost] = [:]
    var dismissedReconnectHostID: UUID?
    var pendingRemoteTabTargetsByTabID: [UUID: RemoteTabSessionTarget] = [:]

    var selectedTab: PaneTab? {
        guard selectedTabIndex >= 0 && selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    override func loadView() {
        let themedView = ThemedPaneView()
        view = themedView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupTabBar()
        setupHomeButton()
        setupICloudButton()
        updateRemoteHostBadge()
        setupPathControl()
        setupReconnectBanner()
        setupTabContainer()
        setupStatusBar()
        setupConstraints()

        // Apply initial theme colors
        updateButtonColors()

        // Observe theme changes to refresh the view
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        // Observe settings changes for status bar visibility
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: SettingsManager.settingsDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSSHConnectionStateChange(_:)),
            name: .sshConnectionStateDidChange,
            object: nil
        )

        // Create initial tab at home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        createTab(at: homeDir, select: true)
    }

    @objc private func handleThemeChange() {
        view.needsDisplay = true
        updatePathControlColors()
        updateRemoteHostBadge()
        updateButtonColors()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePathControl()
    }

    private func setupTabBar() {
        tabBar.delegate = self
        tabBar.paneViewController = self
        view.addSubview(tabBar)
    }

    private func setupHomeButton() {
        homeButton.bezelStyle = .inline
        homeButton.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")
        homeButton.imagePosition = .imageOnly
        homeButton.target = self
        homeButton.action = #selector(homeClicked)
        homeButton.toolTip = "Home"
        homeButton.setAccessibilityIdentifier("homeButton")
        view.addSubview(homeButton)
    }

    private func setupICloudButton() {
        iCloudButton.bezelStyle = .inline
        iCloudButton.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "iCloud Drive")
        iCloudButton.imagePosition = .imageOnly
        iCloudButton.target = self
        iCloudButton.action = #selector(iCloudClicked)
        iCloudButton.toolTip = "iCloud Drive"
        view.addSubview(iCloudButton)
    }

    private func updateButtonColors() {
        let color = ThemeManager.shared.currentTheme.textSecondary
        let config = NSImage.SymbolConfiguration(paletteColors: [color])

        if let homeImage = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")?
            .withSymbolConfiguration(config) {
            homeButton.image = homeImage
        }
        if let iCloudImage = NSImage(systemSymbolName: "icloud", accessibilityDescription: "iCloud Drive")?
            .withSymbolConfiguration(config) {
            iCloudButton.image = iCloudImage
        }
    }

    private func setupPathControl() {
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))
        pathControl.delegate = self
        pathControl.dropDelegate = self
        pathControl.focusRingType = .none
        // Compress gracefully when pane is narrow
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.addSubview(pathControl)

        // Apply theme colors
        updatePathControlColors()
    }

    func updatePathControlColors() {
        let theme = ThemeManager.shared.currentTheme
        // Update path item colors by rebuilding them with attributed titles
        for item in pathControl.pathItems {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: theme.textSecondary,
                .font: ThemeManager.shared.currentTheme.uiFont(size: NSFont.systemFontSize)
            ]
            item.attributedTitle = NSAttributedString(string: item.title, attributes: attrs)
        }
        pathControl.needsDisplay = true
    }

    private func setupTabContainer() {
        view.addSubview(tabContainer)
    }

    private func setupReconnectBanner() {
        reconnectBanner.isHidden = true
        reconnectBanner.wantsLayer = true
        reconnectBanner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        reconnectBanner.setAccessibilityElement(true)
        reconnectBanner.setAccessibilityIdentifier("remoteReconnectBanner")
        reconnectBanner.setAccessibilityRole(.group)

        reconnectBannerLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 12)
        reconnectBannerLabel.textColor = ThemeManager.shared.currentTheme.textPrimary
        reconnectBannerLabel.lineBreakMode = .byTruncatingTail
        reconnectBannerLabel.setAccessibilityIdentifier("remoteReconnectBannerLabel")

        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .small
        reconnectButton.setAccessibilityIdentifier("remoteReconnectButton")
        reconnectButton.setAccessibilityLabel("Reconnect")
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectRemoteHost)

        reconnectDismissButton.bezelStyle = .circular
        reconnectDismissButton.controlSize = .small
        reconnectDismissButton.isBordered = false
        reconnectDismissButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Dismiss"
        )
        reconnectDismissButton.imagePosition = .imageOnly
        reconnectDismissButton.contentTintColor = ThemeManager.shared.currentTheme.textSecondary
        reconnectDismissButton.toolTip = "Dismiss"
        reconnectDismissButton.setAccessibilityIdentifier("remoteReconnectDismiss")
        reconnectDismissButton.setAccessibilityLabel("Dismiss")
        reconnectDismissButton.target = self
        reconnectDismissButton.action = #selector(dismissReconnectBanner)

        reconnectBanner.addSubview(reconnectBannerLabel)
        reconnectBanner.addSubview(reconnectButton)
        reconnectBanner.addSubview(reconnectDismissButton)
        view.addSubview(reconnectBanner)
    }

    private func setupStatusBar() {
        view.addSubview(statusBar)
        statusBar.isHidden = !SettingsManager.shared.settings.showStatusBar
    }

    @objc private func handleSettingsChange() {
        updateStatusBarVisibility()
    }

    func updateStatusBarVisibility() {
        let shouldShow = SettingsManager.shared.settings.showStatusBar
        statusBar.isHidden = !shouldShow

        // Update constraints
        tabContainerBottomConstraint?.isActive = false
        statusBarBottomConstraint?.isActive = false

        if shouldShow {
            tabContainerBottomConstraint = tabContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            statusBarBottomConstraint = statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        } else {
            tabContainerBottomConstraint = tabContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }

        tabContainerBottomConstraint?.isActive = true
        statusBarBottomConstraint?.isActive = true
    }

    private func setupConstraints() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        iCloudButton.translatesAutoresizingMaskIntoConstraints = false
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        reconnectBanner.translatesAutoresizingMaskIntoConstraints = false
        reconnectBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        reconnectDismissButton.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        pathControlLeadingToICloudConstraint = pathControl.leadingAnchor.constraint(equalTo: iCloudButton.trailingAnchor, constant: 6)
        pathControlLeadingToViewConstraint = pathControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8)
        pathControlTrailingConstraint = pathControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        reconnectBannerHeightConstraint = reconnectBanner.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Tab bar at top, 36px height
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            // Path control under tab bar
            pathControl.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            homeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            homeButton.centerYAnchor.constraint(equalTo: pathControl.centerYAnchor),
            homeButton.widthAnchor.constraint(equalToConstant: 24),
            homeButton.heightAnchor.constraint(equalToConstant: 24),

            iCloudButton.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 4),
            iCloudButton.centerYAnchor.constraint(equalTo: pathControl.centerYAnchor),
            iCloudButton.widthAnchor.constraint(equalToConstant: 24),
            iCloudButton.heightAnchor.constraint(equalToConstant: 24),

            pathControlLeadingToICloudConstraint!,
            pathControlTrailingConstraint!,
            pathControl.heightAnchor.constraint(equalToConstant: 24),

            reconnectBanner.topAnchor.constraint(equalTo: pathControl.bottomAnchor),
            reconnectBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reconnectBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reconnectBannerHeightConstraint!,
            reconnectBannerLabel.leadingAnchor.constraint(equalTo: reconnectBanner.leadingAnchor, constant: 10),
            reconnectBannerLabel.centerYAnchor.constraint(equalTo: reconnectBanner.centerYAnchor),
            reconnectButton.leadingAnchor.constraint(greaterThanOrEqualTo: reconnectBannerLabel.trailingAnchor, constant: 8),
            reconnectButton.trailingAnchor.constraint(equalTo: reconnectDismissButton.leadingAnchor, constant: -8),
            reconnectButton.centerYAnchor.constraint(equalTo: reconnectBanner.centerYAnchor),

            reconnectDismissButton.trailingAnchor.constraint(equalTo: reconnectBanner.trailingAnchor, constant: -10),
            reconnectDismissButton.centerYAnchor.constraint(equalTo: reconnectBanner.centerYAnchor),
            reconnectDismissButton.widthAnchor.constraint(equalToConstant: 16),
            reconnectDismissButton.heightAnchor.constraint(equalToConstant: 16),

            // Tab container fills remaining space (bottom constraint handled dynamically)
            tabContainer.topAnchor.constraint(equalTo: reconnectBanner.bottomAnchor),
            tabContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Status bar at bottom, 22px height
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Set up dynamic bottom constraints based on status bar visibility
        updateStatusBarVisibility()
    }
}
