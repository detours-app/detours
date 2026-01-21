import Foundation
import os.log

private let logger = Logger(subsystem: "com.detours", category: "multiwatcher")

/// Monitors multiple directories for filesystem changes using DispatchSource.
/// Supports dynamically adding/removing directories to watch.
final class MultiDirectoryWatcher {
    private let onChange: (URL) -> Void
    private var watchers: [URL: SingleDirectoryWatcher] = [:]

    init(onChange: @escaping (URL) -> Void) {
        self.onChange = onChange
    }

    deinit {
        unwatchAll()
    }

    /// Start watching a directory. If already watching, does nothing.
    func watch(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard watchers[normalized] == nil else { return }

        let watcher = SingleDirectoryWatcher(url: normalized) { [weak self] in
            self?.onChange(normalized)
        }
        watchers[normalized] = watcher
        watcher.start()
    }

    /// Stop watching a directory.
    func unwatch(_ url: URL) {
        let normalized = url.standardizedFileURL
        if let watcher = watchers.removeValue(forKey: normalized) {
            watcher.stop()
        }
    }

    /// Stop watching all directories.
    func unwatchAll() {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
    }

    /// Returns the currently watched URLs.
    var watchedURLs: Set<URL> {
        Set(watchers.keys)
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
