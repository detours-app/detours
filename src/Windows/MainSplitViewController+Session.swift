import AppKit
import os.log

extension MainSplitViewController {
    // MARK: - Session Persistence

    func saveSession() {
        // Cancel any pending debounced save since we're saving now
        saveSessionWorkItem?.cancel()
        saveSessionWorkItem = nil

        defaults.set(leftPane.tabDirectories.map { $0.path }, forKey: SessionKeys.leftTabs)
        defaults.set(leftPane.selectedTabIndex, forKey: SessionKeys.leftSelectedIndex)
        defaults.set(encodeSelections(leftPane.tabSelections), forKey: SessionKeys.leftSelections)
        defaults.set(leftPane.tabShowHiddenFiles, forKey: SessionKeys.leftShowHiddenFiles)
        defaults.set(encodeICloudListingModes(leftPane.tabICloudListingModes), forKey: SessionKeys.leftICloudListingModes)
        defaults.set(encodeExpansions(leftPane.tabExpansions), forKey: SessionKeys.leftExpansions)
        defaults.set(RemoteTabSessionTarget.encode(leftPane.tabRemoteTargets), forKey: SessionKeys.leftRemoteTabs)
        defaults.set(rightPane.tabDirectories.map { $0.path }, forKey: SessionKeys.rightTabs)
        defaults.set(rightPane.selectedTabIndex, forKey: SessionKeys.rightSelectedIndex)
        defaults.set(encodeSelections(rightPane.tabSelections), forKey: SessionKeys.rightSelections)
        defaults.set(rightPane.tabShowHiddenFiles, forKey: SessionKeys.rightShowHiddenFiles)
        defaults.set(encodeICloudListingModes(rightPane.tabICloudListingModes), forKey: SessionKeys.rightICloudListingModes)
        defaults.set(encodeExpansions(rightPane.tabExpansions), forKey: SessionKeys.rightExpansions)
        defaults.set(RemoteTabSessionTarget.encode(rightPane.tabRemoteTargets), forKey: SessionKeys.rightRemoteTabs)
        defaults.set(activePaneIndex, forKey: SessionKeys.activePane)
    }

    /// Schedule a debounced session save (2 second delay, coalesces rapid changes)
    func scheduleSaveSession() {
        // Don't save during session restore
        guard !isRestoringSession else { return }

        // Cancel any existing pending save
        saveSessionWorkItem?.cancel()

        // Schedule new save after delay
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveSession()
        }
        saveSessionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func encodeSelections(_ selections: [[URL]]) -> [[String]] {
        selections.map { urls in urls.map { $0.path } }
    }

    private func encodeICloudListingModes(_ modes: [ICloudListingMode]) -> [String] {
        modes.map(\.rawValue)
    }

    private func decodeICloudListingModes(_ data: Any?) -> [ICloudListingMode]? {
        guard let rawValues = data as? [String] else { return nil }
        return rawValues.compactMap(ICloudListingMode.init(rawValue:))
    }

    private func decodeSelections(_ data: Any?) -> [[URL]]? {
        guard let paths = data as? [[String]] else { return nil }
        return paths.map { pathList in pathList.compactMap { URL(fileURLWithPath: $0) } }
    }

    private func encodeExpansions(_ expansions: [Set<URL>]) -> [[String]] {
        expansions.map { urls in urls.map { $0.path } }
    }

    private func decodeExpansions(_ data: Any?) -> [Set<URL>]? {
        guard let paths = data as? [[String]] else { return nil }
        return paths.map { pathList in Set(pathList.compactMap { URL(fileURLWithPath: $0) }) }
    }

    func restoreSession() {
        if let uiTestRoot = UITestEnvironment.rootDirectory {
            resetUITestRootDirectory(uiTestRoot)
            SettingsManager.shared.folderExpansionEnabled = true
            leftPane.restoreTabs(from: [uiTestRoot], selectedIndex: 0, selections: nil, showHiddenFiles: nil, iCloudListingModes: nil)
            rightPane.restoreTabs(from: [uiTestRoot], selectedIndex: 0, selections: nil, showHiddenFiles: nil, iCloudListingModes: nil)
            do {
                if let host = try UITestEnvironment.persistedRemoteHost() {
                    connectRemoteHost(host)
                } else if let mode = UITestEnvironment.remoteMode {
                    installUITestRemoteTab(root: uiTestRoot, mode: mode)
                }
            } catch { FileOperationQueue.shared.presentError(error) }
            return
        }

        // Check if session restore is enabled in preferences
        guard SettingsManager.shared.restoreSession else {
            // Start fresh with home directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            leftPane.restoreTabs(from: [homeDir], selectedIndex: 0, selections: nil, showHiddenFiles: nil, iCloudListingModes: nil)
            rightPane.restoreTabs(from: [homeDir], selectedIndex: 0, selections: nil, showHiddenFiles: nil, iCloudListingModes: nil)
            return
        }

        restorePane(leftPane, keys: .left)
        restorePane(rightPane, keys: .right)
    }

    /// UI-test seam: turn the left pane's active tab into a remote tab backed by the test root,
    /// so the remote-aware Quick Open tests can run without a live SSH server.
    private func installUITestRemoteTab(root: URL, mode: UITestEnvironment.RemoteMode) {
        let isWindowsFailureMode = mode == .windowsFailed
        let host = RemoteHost(
            displayName: isWindowsFailureMode
                ? UITestEnvironment.windowsRemoteHostDisplayName
                : UITestEnvironment.remoteHostDisplayName,
            sshTarget: isWindowsFailureMode ? "uitest-windows@localhost" : "uitest@localhost",
            kind: isWindowsFailureMode ? .windows : nil
        )
        let provider = UITestRemoteProvider(hostID: host.id, base: root)
        FileOperationQueue.shared.registerRemoteFileProvider(
            provider,
            for: host.id,
            displayName: host.displayName
        )
        guard let tab = leftPane.selectedTab else { return }
        tab.fileListViewController.loadRemoteDirectory(host: host, path: "/", provider: provider)
        if UITestEnvironment.mirrorsRemoteInBothPanes,
           let rightTab = rightPane.selectedTab {
            rightTab.fileListViewController.loadRemoteDirectory(
                host: host,
                path: "/",
                provider: provider
            )
        } else if UITestEnvironment.usesSecondRemoteHost,
                  let rightTab = rightPane.selectedTab {
            let secondHost = RemoteHost(
                displayName: "UITest Server 2",
                sshTarget: "uitest-2@localhost"
            )
            let secondProvider = UITestRemoteProvider(hostID: secondHost.id, base: root)
            FileOperationQueue.shared.registerRemoteFileProvider(
                secondProvider,
                for: secondHost.id,
                displayName: secondHost.displayName
            )
            rightTab.fileListViewController.loadRemoteDirectory(
                host: secondHost,
                path: "/",
                provider: secondProvider
            )
            RemoteConnectionStateStore.shared.setState(.connected, for: secondHost.id)
        }
        switch mode {
        case .connected:
            RemoteConnectionStateStore.shared.setState(.connected, for: host.id)
        case .disconnected:
            RemoteConnectionStateStore.shared.setState(.disconnected, for: host.id)
        case .windowsFailed:
            RemoteConnectionStateStore.shared.setState(.connected, for: host.id)
        }
    }

    private func resetUITestRootDirectory(_ root: URL) {
        // Two shapes of UI-test root reach this: the app-created one, named by prefix, and
        // a guarded qualification root, named by run id and identified by its sentinel.
        // Both are restored to the standard tree on every launch, so one test's fixture
        // changes cannot decide whether a later test in the same run passes.
        let fm = FileManager.default
        let sentinel = root.appendingPathComponent(".detours-qualification-root.json")
        let isAppCreatedRoot = root.lastPathComponent.hasPrefix("DetoursUITests-Temp")
        // A guarded root's sentinel is the harness's own descriptor, and its cleanup
        // refuses to remove a root whose sentinel no longer matches. Carry the exact
        // contents across the reset rather than replacing them with the app's marker.
        let existingSentinel = try? Data(contentsOf: sentinel)
        guard isAppCreatedRoot || existingSentinel != nil else {
            return
        }

        try? fm.removeItem(at: root)

        // The installed-test fixture mutator uses the same fail-closed root
        // contract as qualification roots. Conventional UI-test roots are
        // app-created, so seed their marker before any test requests a mutation.
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? (existingSentinel ?? Data("detours-ui-test-root".utf8)).write(to: sentinel)

        let directories = [
            "AAA_First",
            "BBB_Second/SubfolderB1",
            "BBB_Second/SubfolderB2",
            "CCC_Third",
            "FolderA/SubfolderA1",
            "FolderA/SubfolderA2",
            "FolderB/SubfolderB1",
            "FolderB/SubfolderB2",
            "FolderC",
            "FolderD",
            "Projects2025/Quarterly/Q1",
            "Projects2025/Quarterly/Q2",
            "Projects2025/Annual",
        ]

        for directory in directories {
            try? fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }

        let files: [(String, String)] = [
            ("FolderA/SubfolderA1/file.txt", "test\n"),
            ("FolderA/alpha-file.txt", "test\n"),
            ("FolderB/beta-file.txt", "test\n"),
            ("FolderB/SubfolderB1/nested.txt", "test\n"),
            ("file1.txt", "test\n"),
            ("file2.txt", "test\n"),
            ("zz-target.txt", "target\n"),
            ("FolderB/unique-in-B.txt", "target\n"),
            ("Projects2025/notes.txt", "data\n"),
        ]

        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func restorePane(_ pane: PaneViewController, keys: PaneSessionKeys) {
        guard let paths = defaults.array(forKey: keys.tabs) as? [String], !paths.isEmpty else { return }

        let savedRemoteTargets = RemoteTabSessionTarget.decode(defaults.object(forKey: keys.remoteTabs), count: paths.count)
        var urls: [URL] = []
        var remoteTargets: [RemoteTabSessionTarget?] = []
        var keptIndices: [Int] = []
        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        for (index, path) in paths.enumerated() {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            let existsLocally = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue

            if let target = savedRemoteTargets[index], RemoteHostStore.shared.host(id: target.hostID) != nil {
                // Remote tab: keep it even if its stale local path is gone;
                // home is the placeholder until the host reconnects.
                urls.append(existsLocally ? url : homeDir)
                remoteTargets.append(target)
                keptIndices.append(index)
            } else if existsLocally {
                urls.append(url)
                remoteTargets.append(nil)
                keptIndices.append(index)
            }
        }

        guard !urls.isEmpty else { return }

        // Per-tab arrays were saved aligned with the full tab list; realign them
        // to the surviving tabs so a dropped tab doesn't shift everything after it.
        let savedIndex = defaults.integer(forKey: keys.selectedIndex)
        let selectedIndex = keptIndices.firstIndex(of: savedIndex) ?? 0
        let selections = realigned(decodeSelections(defaults.object(forKey: keys.selections)), keptIndices: keptIndices, originalCount: paths.count)
        let showHiddenFiles = realigned(defaults.array(forKey: keys.showHidden) as? [Bool], keptIndices: keptIndices, originalCount: paths.count)
        let expansions = realigned(decodeExpansions(defaults.object(forKey: keys.expansions)), keptIndices: keptIndices, originalCount: paths.count)
        let iCloudListingModes = realigned(decodeICloudListingModes(defaults.object(forKey: keys.listingModes)), keptIndices: keptIndices, originalCount: paths.count)

        pane.restoreTabs(
            from: urls,
            selectedIndex: selectedIndex,
            selections: selections,
            showHiddenFiles: showHiddenFiles,
            expansions: expansions,
            iCloudListingModes: iCloudListingModes,
            remoteTargets: remoteTargets
        )
    }

    private func realigned<T>(_ array: [T]?, keptIndices: [Int], originalCount: Int) -> [T]? {
        guard let array, array.count == originalCount else { return nil }
        return keptIndices.map { array[$0] }
    }
}
