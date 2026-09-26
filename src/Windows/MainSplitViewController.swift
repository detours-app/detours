import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "split")

enum SplitContentResizePolicy {
    static func proportionalWidths(
        contentWidth: CGFloat,
        previousLeft: CGFloat,
        previousRight: CGFloat,
        minimumLeft: CGFloat,
        minimumRight: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        guard contentWidth > 0 else { return (0, 0) }
        let previousContentWidth = previousLeft + previousRight
        let ratio: CGFloat
        if previousContentWidth > 0 {
            ratio = previousLeft / previousContentWidth
        } else {
            ratio = 0.5
        }

        guard contentWidth >= minimumLeft + minimumRight else {
            let left = floor(contentWidth / 2)
            return (left, contentWidth - left)
        }

        let unclampedLeft = round(contentWidth * ratio)
        let left = min(max(unclampedLeft, minimumLeft), contentWidth - minimumRight)
        return (left, contentWidth - left)
    }
}

struct RemoteHomeDirectoryProbe {
    let sshTarget: String
    let hostTrust: SSHHostTrust

    init(sshTarget: String, hostTrust: SSHHostTrust = SSHHostTrust()) {
        self.sshTarget = sshTarget
        self.hostTrust = hostTrust
    }

    func prepare() throws {
        try hostTrust.prepareKnownHostsFile()
    }

    func arguments() -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
        ] + hostTrust.sshArguments + [
            sshTarget,
            "printf %s \"$HOME\"",
        ]
    }

    func parse(terminationStatus: Int32, stdout: Data, stderr: Data) throws -> String {
        let output = String(data: stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if terminationStatus == 0, !output.isEmpty {
            return output
        }

        let stderrText = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw RemoteFileProviderError.invalidResponse(
            stderrText.isEmpty ? "\(sshTarget) home directory" : stderrText
        )
    }
}

final class MainSplitViewController: NSSplitViewController {
    static let splitViewAutosaveName = "Detours.MainSplitView.AppKitV1"

    let sidebarViewController = SidebarViewController()
    let leftPane = PaneViewController()
    let rightPane = PaneViewController()
    var sidebarSplitViewItem: NSSplitViewItem?
    var activePaneIndex: Int = 0
    var restoreObserverToken: UUID?
    var isRestoringSession = false
    var idleHostProbeTimer: Timer?
    let defaults = UserDefaults.standard
    var lastMediaKeyCode: Int?
    var lastMediaKeyTimestamp: TimeInterval = 0
    var quickNavController: QuickNavController?
    var saveSessionWorkItem: DispatchWorkItem?
    var previousSplitSubviewFrames: [NSRect] = []
    var contentPaneWidthRatio: CGFloat?
    var isSplitResizePolicyActive = false
    var isBalancingContentPaneWidths = false
    var pendingContentPaneBalanceWorkItem: DispatchWorkItem?
    let contentPaneMinimumThickness: CGFloat = 200
    let contentPaneBalanceDelay: TimeInterval = 0.05
    let splitResizeEpsilon: CGFloat = 0.5
    let contentPaneRatioEpsilon: CGFloat = 0.02
    var hasSetInitialFirstResponder = false

    private enum SplitLayout {
        static let sidebarPreferredFraction: CGFloat = 0.25
        static let contentPanePreferredFraction: CGFloat = 0.375
    }

    enum SessionKeys {
        static let leftTabs = "Detours.LeftPaneTabs"
        static let leftSelectedIndex = "Detours.LeftPaneSelectedIndex"
        static let leftSelections = "Detours.LeftPaneSelections"
        static let leftShowHiddenFiles = "Detours.LeftPaneShowHiddenFiles"
        static let leftICloudListingModes = "Detours.LeftPaneICloudListingModes"
        static let rightTabs = "Detours.RightPaneTabs"
        static let rightSelectedIndex = "Detours.RightPaneSelectedIndex"
        static let rightSelections = "Detours.RightPaneSelections"
        static let rightShowHiddenFiles = "Detours.RightPaneShowHiddenFiles"
        static let rightICloudListingModes = "Detours.RightPaneICloudListingModes"
        static let leftExpansions = "Detours.LeftPaneExpansions"
        static let rightExpansions = "Detours.RightPaneExpansions"
        static let leftRemoteTabs = "Detours.LeftPaneRemoteTabs"
        static let rightRemoteTabs = "Detours.RightPaneRemoteTabs"
        static let activePane = "Detours.ActivePane"
    }

    struct PaneSessionKeys {
        let tabs: String
        let remoteTabs: String
        let selectedIndex: String
        let selections: String
        let showHidden: String
        let expansions: String
        let listingModes: String

        static let left = PaneSessionKeys(
            tabs: SessionKeys.leftTabs,
            remoteTabs: SessionKeys.leftRemoteTabs,
            selectedIndex: SessionKeys.leftSelectedIndex,
            selections: SessionKeys.leftSelections,
            showHidden: SessionKeys.leftShowHiddenFiles,
            expansions: SessionKeys.leftExpansions,
            listingModes: SessionKeys.leftICloudListingModes
        )

        static let right = PaneSessionKeys(
            tabs: SessionKeys.rightTabs,
            remoteTabs: SessionKeys.rightRemoteTabs,
            selectedIndex: SessionKeys.rightSelectedIndex,
            selections: SessionKeys.rightSelections,
            showHidden: SessionKeys.rightShowHiddenFiles,
            expansions: SessionKeys.rightExpansions,
            listingModes: SessionKeys.rightICloudListingModes
        )
    }

    deinit {
        guard let token = restoreObserverToken else { return }
        Task { @MainActor in
            FileOperationQueue.shared.removeRestoreObserver(token)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarViewController.delegate = self
        leftPane.splitCoordinator = self
        rightPane.splitCoordinator = self

        // Undo and redo have no calling pane, so the queue announces what a
        // reversal put back and the window reveals it under the same contract.
        restoreObserverToken = FileOperationQueue.shared.addRestoreObserver { [weak self] restored in
            self?.revealOperationResults(
                restored.locations,
                destination: restored.destination,
                affecting: [restored.destination]
            )
        }

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.preferredThicknessFraction = SplitLayout.sidebarPreferredFraction

        let leftPaneItem = NSSplitViewItem(viewController: leftPane)
        leftPaneItem.minimumThickness = contentPaneMinimumThickness
        leftPaneItem.preferredThicknessFraction = SplitLayout.contentPanePreferredFraction

        let rightPaneItem = NSSplitViewItem(viewController: rightPane)
        rightPaneItem.minimumThickness = contentPaneMinimumThickness
        rightPaneItem.preferredThicknessFraction = SplitLayout.contentPanePreferredFraction

        addSplitViewItem(sidebarItem)
        addSplitViewItem(leftPaneItem)
        addSplitViewItem(rightPaneItem)

        sidebarSplitViewItem = sidebarItem
        splitView.autosaveName = NSSplitView.AutosaveName(Self.splitViewAutosaveName)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewSubviewsDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )

        addEqualSplitIndicator()

        isRestoringSession = true
        restoreSession()
        isRestoringSession = false
        warmRemoteHostsOnLaunch()
        startIdleRemoteHostProbing()

        // Restore active pane (defaults to 0 if not saved)
        let savedActivePane = defaults.integer(forKey: SessionKeys.activePane)
        setActivePane(savedActivePane)

        // Listen for focus changes to update active pane
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidUpdateFirstResponder(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        // Listen for volume unmount to navigate affected tabs away
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleVolumeUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )

        // Wire activity strip to file operation queue
        setupActivityCallbacks()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        isSplitResizePolicyActive = false
        DispatchQueue.main.async { [weak self] in
            self?.recordCurrentSplitState()
            self?.isSplitResizePolicyActive = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        preserveContentPaneRatioAfterResize()
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 48 && modifiers.isEmpty { // Tab without modifiers
            switchToOtherPane()
        } else {
            super.keyDown(with: event)
        }
    }

}

// The requirements are implemented across this type's extensions; the panes reach them
// only through this conformance.
extension MainSplitViewController: PaneSplitCoordinating {}
