import Foundation
import os.log

private let logger = Logger(subsystem: "com.detours", category: "multiwatcher")

/// Local FileProvider implementation detail that monitors local directories for filesystem changes.
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
    /// Network volumes use polling only. Local volumes use DispatchSource for instant
    /// structural changes (add/remove/rename) plus polling for metadata changes
    /// (size/date) that DispatchSource cannot detect.
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

            // Poll for in-place metadata changes (touch, echo >>) that kqueue can't detect
            let poller = NetworkDirectoryPoller(url: normalized) { [weak self] in
                self?.onChange(normalized)
            }
            pollers[normalized] = poller
            poller.start()
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
private final class SingleDirectoryWatcher: @unchecked Sendable {
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
        // Open file descriptor on background queue to avoid blocking main thread
        // (open() on network paths can block for seconds)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else {
                logger.warning("Failed to open directory for watching (FD limit?): \(path)")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    Darwin.close(fd)
                    return
                }

                self.fileDescriptor = fd

                self.source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .link, .rename, .delete],
                    queue: .main
                )

                self.source?.setEventHandler { [weak self] in
                    self?.onChange()
                }

                self.source?.setCancelHandler { [weak self] in
                    guard let self, self.fileDescriptor >= 0 else { return }
                    Darwin.close(self.fileDescriptor)
                    self.fileDescriptor = -1
                }

                self.source?.resume()
                logger.debug("Started watching: \(path)")
            }
        }
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
    let fileSize: Int64?
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

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(
            deadline: .now() + Self.pollingInterval,
            repeating: Self.pollingInterval
        )
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer

        // Take initial snapshot on background queue to avoid blocking main thread.
        pollQueue.async { [weak self] in
            self?.lastSnapshot = self?.takeSnapshot()
        }
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
            let snapshotKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: snapshotKeys,
                options: []
            )

            let keySet: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let entries = contents.map { fileURL -> DirectorySnapshotEntry in
                // Clear the NSURL cache so resourceValues re-reads from
                // the VFS instead of returning a stale process-level
                // cached size (e.g. 0 during an in-progress copy).
                (fileURL as NSURL).removeAllCachedResourceValues()
                let values = try? fileURL.resourceValues(forKeys: keySet)
                return DirectorySnapshotEntry(
                    name: fileURL.lastPathComponent,
                    modificationDate: values?.contentModificationDate,
                    fileSize: values?.fileSize.map { Int64($0) }
                )
            }.sorted { $0.name < $1.name }

            return DirectorySnapshot(entries: entries)
        } catch {
            return DirectorySnapshot(entries: [])
        }
    }
}
