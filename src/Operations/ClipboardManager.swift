import AppKit

@MainActor
final class ClipboardManager {
    static let shared = ClipboardManager()
    static let cutItemsDidChange = Notification.Name("ClipboardManager.cutItemsDidChange")

    private let pasteboard = NSPasteboard.general
    private(set) var isCut = false
    private(set) var cutItemURLs: Set<URL> = []

    private init() {}

    var items: [URL] {
        readItems()
    }

    var hasItems: Bool {
        !readItems().isEmpty
    }

    var hasValidItems: Bool {
        let items = readItems()
        guard !items.isEmpty else { return false }
        return items.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    func copy(items: [URL]) {
        write(items: items)
        isCut = false
        cutItemURLs = []
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    func cut(items: [URL]) {
        write(items: items)
        isCut = true
        cutItemURLs = Set(items)
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    @discardableResult
    func paste(to destination: URL) async throws -> [URL] {
        let items = readItems()
        guard !items.isEmpty else { return [] }

        let pastedURLs: [URL]
        if isCut {
            pastedURLs = try await FileOperationQueue.shared.move(items: items, to: destination)
            clear()
        } else {
            pastedURLs = try await FileOperationQueue.shared.copy(items: items, to: destination)
        }
        return pastedURLs
    }

    func clear() {
        pasteboard.clearContents()
        isCut = false
        cutItemURLs = []
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    func isItemCut(_ url: URL) -> Bool {
        cutItemURLs.contains(url)
    }

    // MARK: - Pasteboard

    private func write(items: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items as [NSURL])
    }

    private func readItems() -> [URL] {
        let items = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        return items ?? []
    }
}
