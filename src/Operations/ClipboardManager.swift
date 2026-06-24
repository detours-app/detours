import AppKit

@MainActor
final class ClipboardManager {
    static let shared = ClipboardManager()
    static let cutItemsDidChange = Notification.Name("ClipboardManager.cutItemsDidChange")

    private let pasteboard = NSPasteboard.general
    private var storedLocations: [Location] = []
    private var storedCutItemURLs: Set<URL> = []
    private var storedIsCut = false
    private var storedPasteboardChangeCount = 0

    private init() {}

    var isCut: Bool {
        hasActiveStoredLocations && storedIsCut
    }

    var cutItemURLs: Set<URL> {
        hasActiveStoredLocations ? storedCutItemURLs : []
    }

    var items: [URL] {
        readItems()
    }

    var locations: [Location] {
        readLocations()
    }

    var hasItems: Bool {
        !readLocations().isEmpty
    }

    var hasValidItems: Bool {
        let items = readItems()
        guard !items.isEmpty else { return false }
        return items.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    var hasValidLocations: Bool {
        let locations = readLocations()
        guard !locations.isEmpty else { return false }
        return locations.contains { location in
            switch location {
            case .local(let url):
                return FileManager.default.fileExists(atPath: url.path)
            case .remote:
                return true
            }
        }
    }

    func copy(items: [URL]) {
        copy(items: items.map(Location.local))
    }

    func copy(items: [Location]) {
        write(locations: items)
        storedIsCut = false
        storedCutItemURLs = []
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    func cut(items: [URL]) {
        cut(items: items.map(Location.local))
    }

    func cut(items: [Location]) {
        write(locations: items)
        storedIsCut = true
        storedCutItemURLs = Set(items.compactMap { location in
            if case .local(let url) = location { return url }
            return nil
        })
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    @discardableResult
    func paste(to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let locations = try await paste(to: .local(destination), undoManager: undoManager)
        return locations.compactMap { location in
            if case .local(let url) = location { return url }
            return nil
        }
    }

    @discardableResult
    func paste(to destination: Location, undoManager: UndoManager? = nil) async throws -> [Location] {
        let items = readLocations()
        guard !items.isEmpty else { return [] }

        let pastedItems: [Location]
        if isCut {
            pastedItems = try await FileOperationQueue.shared.move(items: items, to: destination, undoManager: undoManager)
            clear()
        } else {
            pastedItems = try await FileOperationQueue.shared.copy(items: items, to: destination, undoManager: undoManager)
        }
        return pastedItems
    }

    func clear() {
        pasteboard.clearContents()
        storedLocations = []
        storedIsCut = false
        storedCutItemURLs = []
        storedPasteboardChangeCount = pasteboard.changeCount
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    func isItemCut(_ url: URL) -> Bool {
        cutItemURLs.contains(url)
    }

    // MARK: - Pasteboard

    private var hasActiveStoredLocations: Bool {
        !storedLocations.isEmpty && pasteboard.changeCount == storedPasteboardChangeCount
    }

    private func write(locations: [Location]) {
        storedLocations = locations

        let localURLs = locations.compactMap { location -> URL? in
            if case .local(let url) = location { return url }
            return nil
        }
        if localURLs.count == locations.count {
            write(items: localURLs)
        } else {
            pasteboard.clearContents()
            storedPasteboardChangeCount = pasteboard.changeCount
        }
    }

    private func write(items: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items as [NSURL])
        storedPasteboardChangeCount = pasteboard.changeCount
    }

    private func readItems() -> [URL] {
        if hasActiveStoredLocations {
            return storedLocations.compactMap { location in
                if case .local(let url) = location { return url }
                return nil
            }
        }

        let items = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        return items ?? []
    }

    private func readLocations() -> [Location] {
        if hasActiveStoredLocations {
            return storedLocations
        }

        return readItems().map(Location.local)
    }
}
