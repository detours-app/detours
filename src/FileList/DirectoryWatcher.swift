import Foundation
import os.log

private let logger = Logger(subsystem: "com.detour", category: "watcher")

/// Monitors a directory for filesystem changes using DispatchSource.
final class DirectoryWatcher {
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
            logger.error("Failed to open directory for watching: \(path)")
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
