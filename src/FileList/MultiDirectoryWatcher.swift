import Foundation
import os.log

private let logger = Logger(subsystem: "com.detours", category: "multiwatcher")

/// Monitors multiple directories for filesystem changes.
/// Uses DispatchSource for local volumes and polling for network volumes.
final class MultiDirectoryWatcher: @unchecked Sendable {
    private let onChange: @Sendable (URL) -> Void
    private var watchers: [URL: SingleDirectoryWatcher] = [:]
    private var pollers: [URL: NetworkDirectoryPoller] = [:]

    init(onChange: @escaping @Sendable (URL) -> Void) {
        self.onChange = onChange
    }

    deinit {
        unwatchAll()
    }

    /// Start watching a directory. If already watching, does nothing.
    /// Automatically detects network volumes and uses polling instead of DispatchSource.
    func watch(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard watchers[normalized] == nil, pollers[normalized] == nil else { return }

        if VolumeMonitor.isNetworkVolume(normalized) {
            let poller = NetworkDirectoryPoller(url: normalized) { [weak self] in
                self?.onChange(normalized)
            }
            pollers[normalized] = poller
            poller.start()
        } else {
            let watcher = SingleDirectoryWatcher(url: normalized) { [weak self] in
                self?.onChange(normalized)
            }
            watchers[normalized] = watcher
            watcher.start()
        }
    }

    /// Stop watching a directory.
    func unwatch(_ url: URL) {
        let normalized = url.standardizedFileURL
        if let watcher = watchers.removeValue(forKey: normalized) {
            watcher.stop()
        }
        if let poller = pollers.removeValue(forKey: normalized) {
            poller.stop()
        }
    }

    /// Stop watching all directories.
    func unwatchAll() {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
        for poller in pollers.values {
            poller.stop()
        }
        pollers.removeAll()
    }

    /// Returns the currently watched URLs.
    var watchedURLs: Set<URL> {
        Set(watchers.keys).union(pollers.keys)
    }
}

// MARK: - Single Directory Watcher (Internal)

/// Internal class that watches a single directory using DispatchSource.
private final class SingleDirectoryWatcher {
    let url: URL
    private let onChange: () -> Void
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        let path = url.path
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logger.warning("Failed to open directory for watching (FD limit?): \(path)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .link, .rename, .delete],
            queue: .main
        )

        source?.setEventHandler { [weak self] in
            self?.onChange()
        }

        source?.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }

        source?.resume()
        logger.debug("Started watching: \(path)")
    }

    func stop() {
        if let source {
            source.cancel()
            self.source = nil
            logger.debug("Stopped watching: \(self.url.path)")
        }
    }
}

// MARK: - Network Directory Poller

/// Entry in a directory snapshot for comparison
struct DirectorySnapshotEntry: Equatable, Sendable {
    let name: String
    let modificationDate: Date?
}

/// Snapshot of directory contents for change detection
struct DirectorySnapshot: Equatable, Sendable {
    let entries: [DirectorySnapshotEntry]
}

/// Polls a network directory for changes on a background queue.
/// Compares file names and modification dates to detect changes.
/// Uses a serial queue for thread-safe snapshot comparison.
final class NetworkDirectoryPoller: @unchecked Sendable {
    let url: URL
    private let onChange: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private let pollQueue: DispatchQueue

    private var lastSnapshot: DirectorySnapshot?
    static let pollingInterval: TimeInterval = 2.0

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        self.pollQueue = DispatchQueue(label: "com.detours.networkpoller.\(url.lastPathComponent)", qos: .utility)
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        // Take initial snapshot
        lastSnapshot = takeSnapshot()

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(
            deadline: .now() + Self.pollingInterval,
            repeating: Self.pollingInterval
        )
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
        logger.debug("Started polling network directory: \(self.url.path)")
    }

    func stop() {
        if let timer {
            timer.cancel()
            self.timer = nil
            logger.debug("Stopped polling network directory: \(self.url.path)")
        }
        lastSnapshot = nil
    }

    private func poll() {
        let newSnapshot = takeSnapshot()

        guard newSnapshot != lastSnapshot else { return }

        lastSnapshot = newSnapshot

        let callback = onChange
        DispatchQueue.main.async {
            callback()
        }
    }

    private func takeSnapshot() -> DirectorySnapshot {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )

            let entries = contents.map { fileURL -> DirectorySnapshotEntry in
                let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return DirectorySnapshotEntry(
                    name: fileURL.lastPathComponent,
                    modificationDate: modDate
                )
            }.sorted { $0.name < $1.name }

            return DirectorySnapshot(entries: entries)
        } catch {
            return DirectorySnapshot(entries: [])
        }
    }
}
