import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "volumes")

@MainActor
final class VolumeMonitor {
    static let shared = VolumeMonitor()

    /// Notification posted when volumes change
    static let volumesDidChange = Notification.Name("VolumeMonitor.volumesDidChange")

    /// Current list of mounted volumes
    private(set) var volumes: [VolumeInfo] = []

    private init() {
        refreshVolumes()
        startObserving()
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(handleVolumeMount(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleVolumeUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )

        // Also refresh on window activation as fallback
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowActivation(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func handleVolumeMount(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                logger.info("Volume mounted: \(volumeURL.path, privacy: .public)")
                Self.invalidateCaches(for: volumeURL)
            } else {
                logger.info("Volume mounted (unknown path)")
            }
            self?.refreshVolumes()
        }
    }

    @objc private func handleVolumeUnmount(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                logger.info("Volume unmounted: \(volumeURL.path, privacy: .public)")
                Self.invalidateCaches(for: volumeURL)
            } else {
                logger.info("Volume unmounted (unknown path)")
            }
            self?.refreshVolumes()
        }
    }

    /// Invalidate all size caches for a volume so stale data from a
    /// previously-mounted volume at the same mount point is never shown.
    private static func invalidateCaches(for volumeURL: URL) {
        let volumePath = volumeURL.path
        let cache = FolderSizeCache.shared
        for url in cache.allURLs() {
            if url.path.hasPrefix(volumePath) {
                cache.invalidate(url: url)
            }
        }
    }

    @objc private func handleWindowActivation(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshVolumes()
        }
    }

    func refreshVolumes() {
        let resourceKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .effectiveIconKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .isVolumeKey,
            .volumeURLForRemountingKey,
            .volumeUUIDStringKey
        ]

        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: [.skipHiddenVolumes]
        ) else {
            logger.warning("Failed to get mounted volumes")
            volumes = []
            NotificationCenter.default.post(name: Self.volumesDidChange, object: nil)
            return
        }

        var newVolumes: [VolumeInfo] = []
        // Track volume UUIDs to detect zombie mounts — stale network mount
        // points that mirror another volume's identity after disconnection
        var seenUUIDs: [String: Int] = [:]  // UUID -> index in newVolumes

        for url in volumeURLs {
            // Skip hidden system volumes
            if shouldSkipVolume(url) {
                continue
            }

            do {
                let values = try url.resourceValues(forKeys: resourceKeys)

                let name = values.volumeName ?? url.lastPathComponent
                let icon = values.effectiveIcon as? NSImage ?? NSWorkspace.shared.icon(forFile: url.path)
                let capacity = values.volumeTotalCapacity.map { Int64($0) }
                let available = values.volumeAvailableCapacity.map { Int64($0) }
                // The root volume is always local and never ejectable
                let isRootVolume = url.path == "/"

                // A volume can be ejected if it's ejectable, removable, or external (not internal)
                let isEjectable = !isRootVolume && ((values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false) || !(values.volumeIsInternal ?? true))

                // Network detection: volumeIsLocal = false means network volume
                // Root volume is always local regardless of what the system reports
                let isLocal = isRootVolume || (values.volumeIsLocal ?? true)
                let isNetwork = !isLocal

                // Extract server host from remounting URL for network volumes
                var serverHost: String?
                if isNetwork, let remountURL = values.volumeURLForRemounting {
                    serverHost = remountURL.host?.lowercased()
                }

                let volume = VolumeInfo(
                    url: url,
                    name: name,
                    icon: icon,
                    capacity: capacity,
                    availableCapacity: available,
                    isEjectable: isEjectable,
                    isNetwork: isNetwork,
                    serverHost: serverHost
                )

                // Deduplicate by volume UUID: when a network share disconnects
                // unexpectedly, its stale mount point can report the root volume's
                // identity (same UUID, name, capacity) while keeping network metadata.
                if let uuid = values.volumeUUIDString, let existingIdx = seenUUIDs[uuid] {
                    let existing = newVolumes[existingIdx]
                    if volume.isNetwork && !existing.isNetwork {
                        // Zombie network mount mirrors a local volume — skip it
                        logger.warning("Skipping zombie mount '\(name, privacy: .public)' at \(url.path, privacy: .public) (same UUID as \(existing.url.path, privacy: .public))")
                        continue
                    } else if !volume.isNetwork && existing.isNetwork {
                        // Local volume found after a zombie was added — replace the zombie
                        logger.warning("Replacing zombie mount at \(existing.url.path, privacy: .public) with local volume at \(url.path, privacy: .public)")
                        newVolumes[existingIdx] = volume
                        continue
                    }
                }

                newVolumes.append(volume)
                if let uuid = values.volumeUUIDString {
                    seenUUIDs[uuid] = newVolumes.count - 1
                }

                logger.debug("Volume: '\(name, privacy: .public)' at \(url.path, privacy: .public) local=\(isLocal) network=\(isNetwork) ejectable=\(isEjectable)")
            } catch {
                logger.warning("Failed to get volume info for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Sort: non-ejectable (internal) first, then by name
        newVolumes.sort { a, b in
            if a.isEjectable != b.isEjectable {
                return !a.isEjectable
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        volumes = newVolumes
        logger.debug("Refreshed volumes: \(newVolumes.count) found")
        NotificationCenter.default.post(name: Self.volumesDidChange, object: nil)
    }

    /// Returns true if the given URL is on a network volume.
    /// Walks up to the volume root and checks volumeIsLocalKey.
    /// This method is nonisolated because it only reads URL resource values
    /// and does not access any instance state.
    nonisolated static func isNetworkVolume(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.volumeIsLocalKey])
            return !(values.volumeIsLocal ?? true)
        } catch {
            return false
        }
    }

    private func shouldSkipVolume(_ url: URL) -> Bool {
        let path = url.path

        // Skip system volumes
        if path.hasPrefix("/System/Volumes/") {
            return true
        }

        // Skip Preboot, Recovery, VM, etc.
        let skipNames = ["Preboot", "Recovery", "VM", "Update"]
        if skipNames.contains(url.lastPathComponent) {
            return true
        }

        return false
    }
}
