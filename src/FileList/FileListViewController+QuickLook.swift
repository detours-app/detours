import AppKit
import os.log
@preconcurrency import Quartz

// MARK: - Quick Look

extension FileListViewController {
    func toggleQuickLook() {
        if detoursPreviewWindow?.isPresented == true {
            closeDetoursPreviewWindow()
            return
        }

        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible {
            clearQuickLookPreviewState()
            panel.orderOut(nil)
        } else if let remoteItem = selectedRemoteQuickLookItem() {
            startRemoteQuickLook(for: remoteItem, panel: panel)
        } else {
            startLocalQuickLookGeneration(urls: selectedURLs, panel: panel)
        }
    }

    private func startLocalQuickLookGeneration(urls: [URL], panel: QLPreviewPanel?) {
        guard !urls.isEmpty else { return }
        let requestID = UUID()
        quickLookRequestID = requestID
        quickLookGenerationTask?.cancel()
        // Whatever is on screen stays there until the next preview is ready. Emptying the panel
        // first left it blank for as long as generation took, which reads as a white flash between
        // files.

        let generator = quickLookPreviewGenerator
        let theme = ThemeManager.shared.currentTheme
        let fontSize = ThemeManager.shared.fontSize
        let wrapLines = SettingsManager.shared.previewWrapLines
        quickLookGenerationTask = Task { @MainActor in
            do {
                var previews: [DetoursQuickLookItem] = []
                previews.reserveCapacity(urls.count)
                for url in urls {
                    try Task.checkCancellation()
                    let preview = try await generator.previewURL(for: DetoursPreviewRequest(
                        sourceURL: url,
                        displayName: url.lastPathComponent,
                        theme: theme,
                        fontSize: fontSize,
                        context: .local,
                        wrapLines: wrapLines
                    ))
                    previews.append(DetoursQuickLookItem(url: preview, title: url.lastPathComponent))
                }
                guard self.quickLookRequestID == requestID else { return }
                self.quickLookPreviewItems = previews
                self.quickLookGenerationTask = nil

                // A preview Detours generated is shown in a window Detours owns. Anything handed
                // back unchanged, such as an image, is left to the system panel, which shows those
                // without the blank white stage its document viewer has.
                if let generated = previews.first,
                   let previewURL = generated.previewItemURL,
                   previewURL.standardizedFileURL != urls.first?.standardizedFileURL {
                    if panel?.isVisible == true {
                        self.clearQuickLookPreviewState(cancelTasks: false)
                        panel?.orderOut(nil)
                    }
                    self.showDetoursPreview(url: previewURL, title: generated.previewItemTitle ?? "")
                    return
                }

                self.closeDetoursPreviewWindow()
                // Only bring the panel up when it is not already showing. Ordering a visible panel
                // to the front again on every keystroke disturbs it for no reason.
                if let panel, !panel.isVisible {
                    panel.makeKeyAndOrderFront(nil)
                }
                panel?.reloadData()
            } catch is CancellationError {
                if self.quickLookRequestID == requestID {
                    self.quickLookGenerationTask = nil
                }
            } catch {
                guard self.quickLookRequestID == requestID else { return }
                self.clearQuickLookPreviewState(cancelTasks: false)
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func selectedRemoteQuickLookItem() -> FileItem? {
        guard selectedItems.count == 1,
              let item = selectedItems.first,
              !item.isNavigableFolder,
              !item.isSymbolicLink else {
            return nil
        }
        guard case .remote = item.location else { return nil }
        return item
    }

    private func startRemoteQuickLook(for item: FileItem, panel: QLPreviewPanel) {
        guard let provider = currentRemoteProvider,
              case .remote(let hostID, _) = item.location else {
            return
        }

        if remoteQuickLookRequestLocation == item.location,
           remoteQuickLookTask != nil {
            return
        }

        remoteQuickLookTask?.cancel()
        quickLookGenerationTask?.cancel()
        quickLookPreviewItems = []
        quickLookRequestID = UUID()
        remoteQuickLookRequestLocation = item.location
        hideRemoteQuickLookProgressOverlay()

        remoteQuickLookTask = Task { @MainActor in
            do {
                let entry = try await provider.stat(item.location)
                try Task.checkCancellation()
                guard remoteQuickLookRequestLocation == item.location else { return }

                let byteCount = entry.fileSize ?? 0
                guard byteCount <= RemoteFileCache.quickLookMaximumBytes else {
                    clearRemoteQuickLookState(cancelTask: false)
                    presentRemoteQuickLookTooLarge(fileName: item.name, byteCount: byteCount)
                    return
                }

                let previewURL = try RemoteFileCache.makeSessionFile(hostID: hostID, remotePath: item.location.path)
                if byteCount >= RemoteFileCache.progressMinimumBytes {
                    panel.makeKeyAndOrderFront(nil)
                    panel.reloadData()
                    showRemoteQuickLookProgressOverlay(in: panel, byteCount: byteCount)
                }

                try await provider.download(item.location, to: previewURL)
                try Task.checkCancellation()
                guard remoteQuickLookRequestLocation == item.location else { return }

                let generatedPreviewURL = try await quickLookPreviewGenerator.previewURL(for: DetoursPreviewRequest(
                    sourceURL: previewURL,
                    displayName: item.name,
                    theme: ThemeManager.shared.currentTheme,
                    fontSize: ThemeManager.shared.fontSize,
                    context: .remote,
                    wrapLines: SettingsManager.shared.previewWrapLines
                ))
                try Task.checkCancellation()
                guard remoteQuickLookRequestLocation == item.location else { return }

                quickLookPreviewItems = [DetoursQuickLookItem(url: generatedPreviewURL, title: item.name)]
                remoteQuickLookTask = nil
                hideRemoteQuickLookProgressOverlay()
                panel.makeKeyAndOrderFront(nil)
                panel.reloadData()
            } catch is CancellationError {
                if remoteQuickLookRequestLocation == item.location {
                    remoteQuickLookTask = nil
                }
            } catch {
                guard remoteQuickLookRequestLocation == item.location else { return }
                clearRemoteQuickLookState(cancelTask: false)
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func clearRemoteQuickLookState(cancelTask: Bool = true) {
        if cancelTask {
            remoteQuickLookTask?.cancel()
        }
        remoteQuickLookTask = nil
        remoteQuickLookRequestLocation = nil
        hideRemoteQuickLookProgressOverlay()
    }

    func clearQuickLookPreviewState(cancelTasks: Bool = true) {
        if cancelTasks {
            quickLookGenerationTask?.cancel()
        }
        quickLookGenerationTask = nil
        quickLookRequestID = UUID()
        quickLookPreviewItems = []
        clearRemoteQuickLookState(cancelTask: cancelTasks)
    }

    private func presentRemoteQuickLookTooLarge(fileName: String, byteCount: Int64) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: byteCount)
        FileOperationQueue.shared.presentError(
            FileProviderError.unsupportedOperation("\"\(fileName)\" is \(size). Remote Quick Look supports files up to 100 MB.")
        )
    }

    private func showRemoteQuickLookProgressOverlay(in panel: QLPreviewPanel, byteCount: Int64) {
        hideRemoteQuickLookProgressOverlay()
        guard let contentView = panel.contentView else { return }

        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(max(byteCount, 1))
        progress.doubleValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.setAccessibilityLabel("Remote Quick Look download progress")

        let label = NSTextField(labelWithString: "Downloading remote preview...")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(progress)
        overlay.addSubview(label)
        contentView.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            progress.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 260),

            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -12),
        ])

        remoteQuickLookProgressOverlay = overlay
    }

    private func hideRemoteQuickLookProgressOverlay() {
        remoteQuickLookProgressOverlay?.removeFromSuperview()
        remoteQuickLookProgressOverlay = nil
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            Self.quickLookPreviewItemCount(
                remoteRequestActive: remoteQuickLookRequestLocation != nil,
                remotePreviewReady: !quickLookPreviewItems.isEmpty,
                selectedURLCount: selectedURLs.count,
                generatedPreviewCount: quickLookPreviewItems.count,
                generationActive: quickLookGenerationTask != nil
            )
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            if !quickLookPreviewItems.isEmpty {
                guard index >= 0 && index < quickLookPreviewItems.count else { return nil }
                return quickLookPreviewItems[index]
            }
            if remoteQuickLookRequestLocation != nil {
                return nil
            }
            let urls = selectedURLs
            guard index >= 0 && index < urls.count else { return nil }
            return urls[index] as NSURL
        }
    }

    static func quickLookPreviewItemCount(
        remoteRequestActive: Bool,
        remotePreviewReady: Bool,
        selectedURLCount: Int,
        generatedPreviewCount: Int = 0,
        generationActive: Bool = false
    ) -> Int {
        if remoteRequestActive {
            return remotePreviewReady ? 1 : 0
        }
        if generationActive {
            // Report the previews already on screen so the panel keeps showing the previous file
            // while the next one is built. Falling through to the selected URLs instead would hand
            // the panel raw files and flash a system-drawn preview before the Detours one.
            return generatedPreviewCount
        }
        if generatedPreviewCount > 0 {
            return generatedPreviewCount
        }
        return selectedURLCount
    }

    // MARK: - QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event else { return false }
        // Handle arrow keys to navigate the file list while Quick Look is open
        if event.type == .keyDown {
            let keyCode = event.keyCode
            // Option-W while previewing: the panel is in front, so the key is claimed here rather
            // than left to the menu, and the preview is rebuilt with the new setting.
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if modifiers == .option, event.charactersIgnoringModifiers?.lowercased() == "w" {
                MainActor.assumeIsolated {
                    SettingsManager.shared.previewWrapLines.toggle()
                    refreshQuickLookPanel()
                }
                return true
            }
            // Up (126), Down (125) arrow keys - navigate selection
            if keyCode == 126 || keyCode == 125 {
                MainActor.assumeIsolated {
                    let current = tableView.selectedRow
                    let rowCount = tableView.numberOfRows
                    if keyCode == 126 && current > 0 {
                        // Up arrow
                        tableView.selectRowIndexes(IndexSet(integer: current - 1), byExtendingSelection: false)
                        tableView.scrollRowToVisible(current - 1)
                    } else if keyCode == 125 && current < rowCount - 1 {
                        // Down arrow
                        tableView.selectRowIndexes(IndexSet(integer: current + 1), byExtendingSelection: false)
                        tableView.scrollRowToVisible(current + 1)
                    }
                }
                return true
            }
        }
        return false
    }

    // MARK: - Detours-owned preview window

    private func showDetoursPreview(url: URL, title: String) {
        let theme = ThemeManager.shared.currentTheme
        if let existing = detoursPreviewWindow, existing.isPresented {
            existing.update(previewURL: url, title: title, theme: theme)
            return
        }
        let controller = detoursPreviewWindow ?? DetoursPreviewWindowController(theme: theme)
        controller.previewDelegate = self
        detoursPreviewWindow = controller
        controller.present(previewURL: url, title: title, theme: theme)
    }

    func closeDetoursPreviewWindow() {
        guard let controller = detoursPreviewWindow, controller.isPresented else { return }
        controller.close(notifyingDelegate: false)
        quickLookGenerationTask?.cancel()
        quickLookGenerationTask = nil
        quickLookPreviewItems = []
    }

    func refreshQuickLookPanel() {
        if detoursPreviewWindow?.isPresented == true {
            clearRemoteQuickLookState()
            startLocalQuickLookGeneration(urls: selectedURLs, panel: QLPreviewPanel.shared())
            return
        }
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        if let remoteItem = selectedRemoteQuickLookItem() {
            startRemoteQuickLook(for: remoteItem, panel: panel)
            return
        }
        clearRemoteQuickLookState()
        startLocalQuickLookGeneration(urls: selectedURLs, panel: panel)
    }

    // MARK: - Quick Look Test Hooks

    func startLocalQuickLookGenerationForTesting(urls: [URL]) {
        startLocalQuickLookGeneration(urls: urls, panel: nil)
    }

    func prepareRemoteQuickLookPreviewForTesting(downloadedURL: URL, displayName: String) async throws {
        let generated = try await quickLookPreviewGenerator.previewURL(for: DetoursPreviewRequest(
            sourceURL: downloadedURL,
            displayName: displayName,
            theme: ThemeManager.shared.currentTheme,
            fontSize: ThemeManager.shared.fontSize,
            context: .remote,
            wrapLines: SettingsManager.shared.previewWrapLines
        ))
        quickLookPreviewItems = [DetoursQuickLookItem(url: generated, title: displayName)]
    }

    var quickLookPreviewURLsForTesting: [URL] {
        quickLookPreviewItems.compactMap(\.previewItemURL)
    }

    var quickLookPreviewTitlesForTesting: [String] {
        quickLookPreviewItems.compactMap(\.previewItemTitle)
    }

    var quickLookGenerationTaskIsActiveForTesting: Bool {
        quickLookGenerationTask != nil
    }
}

// MARK: - DetoursPreviewWindowDelegate

extension FileListViewController: DetoursPreviewWindowDelegate {
    func previewWindowDidRequestClose() {
        detoursPreviewWindow?.close(notifyingDelegate: false)
        quickLookGenerationTask?.cancel()
        quickLookGenerationTask = nil
        quickLookPreviewItems = []
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(tableView)
    }

    func previewWindowDidRequestMoveSelection(down: Bool) {
        let current = tableView.selectedRow
        let rowCount = tableView.numberOfRows
        let target = down ? current + 1 : current - 1
        guard target >= 0, target < rowCount else { return }
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        tableView.scrollRowToVisible(target)
    }

    func previewWindowDidRequestWrapToggle() {
        SettingsManager.shared.previewWrapLines.toggle()
        refreshQuickLookPanel()
    }
}
