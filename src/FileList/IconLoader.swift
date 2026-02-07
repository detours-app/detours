import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "iconloader")

actor IconLoader {
    static let shared = IconLoader()

    private var cache: [URL: NSImage] = [:]

    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()

    // Placeholder icons loaded once from system constants
    static let placeholderFileIcon: NSImage = {
        NSWorkspace.shared.icon(for: .item)
    }()

    static let placeholderFolderIcon: NSImage = {
        NSWorkspace.shared.icon(for: .folder)
    }()

    func icon(for url: URL, isDirectory: Bool, isPackage: Bool) async -> NSImage {
        if let cached = cache[url] {
            return cached
        }

        let image = await loadIcon(for: url)
        cache[url] = image
        return image
    }

    private func loadIcon(for url: URL) async -> NSImage {
        await withCheckedContinuation { continuation in
            operationQueue.addOperation {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                continuation.resume(returning: icon)
            }
        }
    }

    func invalidate(_ url: URL) {
        cache.removeValue(forKey: url)
    }

    func invalidateAll() {
        cache.removeAll()
    }
}
