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
        logger.info("Volume mounted")
        refreshVolumes()
    }

    @objc private func handleVolumeUnmount(_ notification: Notification) {
        logger.info("Volume unmounted")
        refreshVolumes()
    }

    @objc private func handleWindowActivation(_ notification: Notification) {
        refreshVolumes()
    }

    func refreshVolumes() {
        let resourceKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsEjectableKey,
            .effectiveIconKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .isVolumeKey
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
                let isEjectable = values.volumeIsEjectable ?? false

                let volume = VolumeInfo(
                    url: url,
                    name: name,
                    icon: icon,
                    capacity: capacity,
                    availableCapacity: available,
                    isEjectable: isEjectable
                )
                newVolumes.append(volume)
            } catch {
                logger.warning("Failed to get volume info for \(url.path): \(error.localizedDescription)")
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
