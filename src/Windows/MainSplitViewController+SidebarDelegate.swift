import AppKit
import os.log

// MARK: - SidebarDelegate

private let logger = Logger(subsystem: "com.detours", category: "split")

extension MainSplitViewController: SidebarDelegate {
    func sidebarDidSelectItem(_ item: SidebarItem) {
        if case .remoteHost(let host) = item {
            connectRemoteHost(host)
            return
        }

        guard let url = item.url else { return }
        navigateActivePane(to: url)
        // Restore focus to the active pane's file list
        view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
    }

    func sidebarDidSelectServer(_ server: NetworkServer) {
        Task {
            await mountNetworkServer(server)
        }
    }

    func sidebarDidRequestEject(_ volume: VolumeInfo) {
        let volumeURL = volume.url
        let volumeName = volume.name
        let isNetwork = volume.isNetwork
        Task.detached {
            do {
                // Check if this volume is a disk image (DMG, sparsebundle, etc.)
                // NSWorkspace.unmountAndEjectDevice doesn't fully detach disk images
                if let deviceToDetach = Self.diskImageDevice(for: volumeURL) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    process.arguments = ["detach", deviceToDetach]
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        throw NSError(
                            domain: "Detours",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "hdiutil detach failed"]
                        )
                    }
                } else if isNetwork {
                    // Use diskutil for network volumes - handles busy volumes better
                    try Self.unmountWithDiskutil(volumeURL)
                } else {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
                }
            } catch {
                await MainActor.run {
                    logger.error("Failed to eject volume: \(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = "Could not eject \"\(volumeName)\""
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private nonisolated static func unmountWithDiskutil(_ url: URL, force: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount"] + (force ? ["force"] : []) + [url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            // If regular unmount failed and we haven't tried force yet, try with force
            if !force {
                try unmountWithDiskutil(url, force: true)
                return
            }
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "Detours",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }

    func sidebarDidRequestEjectServer(host: String) {
        // Find all volumes from this server and eject them
        let volumes = VolumeMonitor.shared.volumes.filter { volume in
            guard let volumeHost = volume.serverHost else { return false }
            return volumeHost.lowercased() == host.lowercased() ||
                   volumeHost.lowercased().hasPrefix(host.lowercased() + ".") ||
                   host.lowercased().hasPrefix(volumeHost.lowercased() + ".")
        }

        guard !volumes.isEmpty else { return }

        Task.detached {
            var errors: [(String, Error)] = []
            for volume in volumes {
                do {
                    // Use diskutil for network volumes - handles busy volumes better
                    try Self.unmountWithDiskutil(volume.url)
                } catch {
                    errors.append((volume.name, error))
                }
            }

            if !errors.isEmpty {
                await MainActor.run {
                    let alert = NSAlert()
                    if errors.count == 1 {
                        alert.messageText = "Could not eject \"\(errors[0].0)\""
                        alert.informativeText = errors[0].1.localizedDescription
                    } else {
                        alert.messageText = "Could not eject \(errors.count) volumes"
                        alert.informativeText = errors.map { $0.0 }.joined(separator: ", ")
                    }
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    /// Returns the device identifier to detach if the volume is a disk image, nil otherwise
    private nonisolated static func diskImageDevice(for volumeURL: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let images = plist["images"] as? [[String: Any]] else {
                return nil
            }

            let volumePath = volumeURL.path
            for image in images {
                guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
                for entity in entities {
                    if let mountPoint = entity["mount-point"] as? String, mountPoint == volumePath {
                        // Found the disk image - return the parent device to detach
                        // Use the dev-entry from the first entity (the whole disk)
                        if let firstEntity = entities.first, let devEntry = firstEntity["dev-entry"] as? String {
                            return devEntry
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to get disk image info: \(error.localizedDescription)")
        }

        return nil
    }

    func sidebarDidAddFavorite(_ url: URL, at index: Int?) {
        var favorites = SettingsManager.shared.favorites
        let path = url.path
        guard !favorites.contains(path) else { return }
        if let index = index {
            let insertIndex = min(index, favorites.count)
            favorites.insert(path, at: insertIndex)
        } else {
            favorites.append(path)
        }
        SettingsManager.shared.favorites = favorites
    }

    func sidebarDidRemoveFavorite(_ url: URL) {
        var favorites = SettingsManager.shared.favorites
        favorites.removeAll { $0 == url.path }
        SettingsManager.shared.favorites = favorites
    }

    func sidebarDidRemoveRemoteHost(_ host: RemoteHost) {
        let alert = NSAlert()
        alert.messageText = "Eject \"\(host.displayName)\"?"
        alert.informativeText = "This removes the remote host from the sidebar and moves any tabs using it back to a local folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eject")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        RemoteHostStore.shared.remove(id: host.id)
        remoteConnectionResources.removeValue(forKey: host.id)
        FileOperationQueue.shared.unregisterRemoteFileProvider(for: host.id)
        leftPane.navigateTabsViewingRemovedRemoteHost(host.id)
        rightPane.navigateTabsViewingRemovedRemoteHost(host.id)
        Task {
            await RemoteConnectionRegistry.shared.unregister(hostID: host.id)
        }
    }

    func sidebarDidReorderFavorites(_ urls: [URL]) {
        SettingsManager.shared.favorites = urls.map { $0.path }
    }

    func sidebarDidDropFiles(_ urls: [URL], to destination: URL, isCopy: Bool) {
        var affected: Set<Location> = [.local(destination.standardizedFileURL)]
        for url in urls {
            affected.insert(.local(url.deletingLastPathComponent().standardizedFileURL))
        }
        Task { @MainActor in
            do {
                let results = try await PaneFileOperationCoordinator.shared.perform(affecting: affected) {
                    if isCopy {
                        return try await FileOperationQueue.shared.copy(items: urls, to: destination, undoManager: undoManager)
                    }
                    return try await FileOperationQueue.shared.move(items: urls, to: destination, undoManager: undoManager)
                }
                revealOperationResults(
                    results.map(Location.local),
                    destination: .local(destination.standardizedFileURL),
                    affecting: affected
                )
                refreshAffectedPanes(sources: urls, destination: destination)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func refreshAffectedPanes(sources: [URL], destination: URL) {
        var affectedDirs = Set<URL>()
        affectedDirs.insert(destination.standardizedFileURL)
        for url in sources {
            affectedDirs.insert(url.deletingLastPathComponent().standardizedFileURL)
        }

        for pane in [leftPane, rightPane] {
            if let currentDir = pane.currentDirectory?.standardizedFileURL,
               affectedDirs.contains(currentDir) {
                pane.refresh()
            }
        }
    }
}
