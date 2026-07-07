import AppKit
import os.log
@preconcurrency import Quartz

// MARK: - Responder Actions

extension FileListViewController {
    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    @objc func cut(_ sender: Any?) {
        cutSelection()
    }

    @objc func paste(_ sender: Any?) {
        pasteHere()
    }

    @objc func filter(_ sender: Any?) {
        showFilterBar()
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    @objc func deleteImmediately(_ sender: Any?) {
        deleteSelectionImmediately()
    }

    @objc func duplicate(_ sender: Any?) {
        duplicateSelection()
    }

    @objc func archive(_ sender: Any?) {
        archiveSelection()
    }

    @objc func extractArchive(_ sender: Any?) {
        extractSelectedArchive()
    }

    @objc func newFolder(_ sender: Any?) {
        createNewFolder()
    }

    @objc func newTextFile(_ sender: Any?) {
        createNewFile(name: "Text File.txt")
    }

    @objc func newMarkdownFile(_ sender: Any?) {
        createNewFile(name: "Document.md")
    }

    @objc func newEmptyFile(_ sender: Any?) {
        promptForNewFile()
    }

    /// Escape a string for safe interpolation into AppleScript
    private func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @objc func getInfo(_ sender: Any?) {
        let items = selectedItems
        let urls = items.compactMap { item -> URL? in
            guard case .local(let url) = item.location else { return nil }
            return url
        }
        let remoteItems = items.filter(\.isRemote)

        if !urls.isEmpty {
            openLocalInfoWindows(for: urls)
        }
        if !remoteItems.isEmpty {
            openRemoteInfoWindows(for: remoteItems)
        }
    }

    private func openLocalInfoWindows(for urls: [URL]) {
        guard !urls.isEmpty else { return }

        // Get window position to place info window to the left of Detours
        let windowFrame = view.window?.frame ?? NSRect(x: 100, y: 100, width: 800, height: 600)
        let screenHeight = Int(NSScreen.main?.frame.height ?? 900)

        // Info window is about 265x630
        let infoWidth = 265
        let infoHeight = 630
        let baseX = Int(windowFrame.minX) - infoWidth - 20  // 20px gap to the left
        let baseY = screenHeight - Int(windowFrame.midY) - infoHeight / 2

        // Get count of existing info windows BEFORE opening new ones
        var existingCount = 0
        if let result = NSAppleScript(source: "tell application \"Finder\" to count of information windows")?.executeAndReturnError(nil) {
            existingCount = Int(result.int32Value)
        }

        // Open the windows
        let openLines = urls.map { "open information window of (POSIX file \"\(escapeForAppleScript($0.path))\" as alias)" }
        let openScript = "tell application \"Finder\"\n    activate\n" + openLines.map { "    " + $0 }.joined(separator: "\n") + "\nend tell"
        NSAppleScript(source: openScript)?.executeAndReturnError(nil)

        // Position windows after a brief delay - cascade down and LEFT
        let capturedURLs = urls
        let capturedBaseX = baseX
        let capturedBaseY = baseY
        let startIndex = existingCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            var positionLines: [String] = []
            for (i, url) in capturedURLs.enumerated() {
                let offset = startIndex + i
                let x1 = capturedBaseX - (offset * 25)  // CASCADE LEFT
                let y1 = capturedBaseY + (offset * 25)  // CASCADE DOWN
                let x2 = x1 + infoWidth
                let y2 = y1 + infoHeight
                let windowName = url.lastPathComponent + " Info"
                positionLines.append("set bounds of information window \"\(self.escapeForAppleScript(windowName))\" to {\(x1), \(y1), \(x2), \(y2)}")
            }
            let positionScript = "tell application \"Finder\"\n" + positionLines.map { "    " + $0 }.joined(separator: "\n") + "\nend tell"
            NSAppleScript(source: positionScript)?.executeAndReturnError(nil)
        }
    }

    private func openRemoteInfoWindows(for items: [FileItem]) {
        guard let provider = currentRemoteProvider else { return }
        let hostName = currentRemoteHost?.displayName ?? "Remote Host"

        for (index, item) in items.enumerated() {
            Task { @MainActor in
                do {
                    let snapshot = try await makeRemoteInfoSnapshot(for: item, hostName: hostName, provider: provider)
                    showRemoteInfoWindow(snapshot: snapshot, icon: item.icon, offset: index)
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
    }

    private func makeRemoteInfoSnapshot(
        for item: FileItem,
        hostName: String,
        provider: any FileProvider
    ) async throws -> RemoteInfoSnapshot {
        let entry = try await provider.stat(item.location)
        let sizeText: String
        if entry.isDirectory {
            if let size = try? await provider.folderSize(for: item.location) {
                sizeText = formatInfoByteCount(size)
            } else {
                sizeText = "—"
            }
        } else if let fileSize = entry.fileSize {
            sizeText = formatInfoByteCount(fileSize)
        } else {
            sizeText = "—"
        }

        let symlinkTarget: String?
        if entry.isSymbolicLink {
            symlinkTarget = (try? await provider.readSymlink(item.location).path) ?? "Unavailable"
        } else {
            symlinkTarget = nil
        }

        return RemoteInfoSnapshot(
            name: entry.name,
            kind: remoteInfoKind(for: entry),
            host: hostName,
            path: entry.location.path,
            size: sizeText,
            modified: formatInfoDate(entry.contentModificationDate),
            hidden: entry.isHidden ? "Yes" : "No",
            readable: entry.isReadable ? "Yes" : "No",
            symlinkTarget: symlinkTarget
        )
    }

    private func showRemoteInfoWindow(snapshot: RemoteInfoSnapshot, icon: NSImage, offset: Int) {
        let controller = RemoteInfoWindowController(snapshot: snapshot, icon: icon)
        controller.onClose = { [weak self] closedController in
            self?.remoteInfoWindows.removeAll { $0 === closedController }
        }
        remoteInfoWindows.append(controller)

        if let window = controller.window {
            let parentFrame = view.window?.frame ?? NSRect(x: 100, y: 100, width: 800, height: 600)
            let x = max(20, parentFrame.minX - window.frame.width - 20 - CGFloat(offset * 25))
            let y = max(20, parentFrame.midY - window.frame.height / 2 + CGFloat(offset * 25))
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
    }

    private func remoteInfoKind(for entry: LoadedFileEntry) -> String {
        if entry.isSymbolicLink { return "Symbolic Link" }
        if entry.isDirectory { return "Folder" }
        if entry.isPackage { return "Package" }
        return "File"
    }

    private func formatInfoByteCount(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    private func formatInfoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    @objc func copyPath(_ sender: Any?) {
        let locations = selectedLocations
        guard !locations.isEmpty else { return }
        let paths = locations.map { $0.path.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func shareViaService(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        service.perform(withItems: urls)
    }

    // MARK: - Navigation Actions (for menu responder chain)

    @objc func goBack(_ sender: Any?) {
        navigationDelegate?.fileListDidRequestBack()
    }

    @objc func goForward(_ sender: Any?) {
        navigationDelegate?.fileListDidRequestForward()
    }

    @objc func goUp(_ sender: Any?) {
        navigationDelegate?.fileListDidRequestParentNavigation()
    }
}
