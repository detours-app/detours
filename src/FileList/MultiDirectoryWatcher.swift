import CoreServices
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

/// Internal class that watches a single directory using FSEvents.
/// FSEvents detects all changes including in-place file modifications
/// (touch, echo >>), unlike DispatchSource which only detects directory
/// entry changes (add/remove/rename).
private final class SingleDirectoryWatcher: @unchecked Sendable {
    let url: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        // Use realpath to resolve firmlinks (e.g. /var → /private/var)
        // so the path matches what FSEvents uses internally
        let resolvedPath: String
        if let rp = realpath(url.path, nil) {
            resolvedPath = String(cString: rp)
            free(rp)
        } else {
            resolvedPath = url.path
        }

        let pathsToWatch = [resolvedPath] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // No path filtering — any event in this directory tree triggers onChange.
        // The stream is already scoped to the watched directory, and the existing
        // debounce in handleDirectoryChange coalesces rapid events.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SingleDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            UInt32(kFSEventStreamCreateFlagNoDefer)
        ) else {
            logger.warning("Failed to create FSEventStream for: \(resolvedPath)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        logger.debug("Started watching: \(resolvedPath)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        logger.debug("Stopped watching: \(self.url.path)")
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

        // Take initial snapshot on background queue to avoid blocking main thread
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        pollQueue.async { [weak self] in
            guard let self else { return }
            self.lastSnapshot = self.takeSnapshot()

            timer.schedule(
                deadline: .now() + Self.pollingInterval,
                repeating: Self.pollingInterval
            )
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            self.timer = timer
            timer.resume()
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
