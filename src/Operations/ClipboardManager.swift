import AppKit

@MainActor
final class ClipboardManager {
    static let shared = ClipboardManager()
    static let cutItemsDidChange = Notification.Name("ClipboardManager.cutItemsDidChange")

    private let pasteboard = NSPasteboard.general
    private var storedLocations: [Location] = []
    private var storedCutItemLocations: Set<Location> = []
    private var storedIsCut = false
    private var storedPasteboardChangeCount = 0

    private init() {}

    var isCut: Bool {
        hasActiveStoredLocations && storedIsCut
    }

    var cutItemURLs: Set<URL> {
        Set(cutItemLocations.compactMap { location in
            guard case .local(let url) = location else { return nil }
            return url
        })
    }

    var cutItemLocations: Set<Location> {
        hasActiveStoredLocations ? storedCutItemLocations : []
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
        storedCutItemLocations = []
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    func cut(items: [URL]) {
        cut(items: items.map(Location.local))
    }

    func cut(items: [Location]) {
        write(locations: items)
        storedIsCut = true
        storedCutItemLocations = Set(items)
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
        let operationIsCut = isCut
        let owningPasteboardChangeCount = storedPasteboardChangeCount

        let pastedItems: [Location]
        if operationIsCut {
            pastedItems = try await FileOperationQueue.shared.move(items: items, to: destination, undoManager: undoManager)
            finishSuccessfulCutPaste(
                owningPasteboardChangeCount: owningPasteboardChangeCount
            )
        } else {
            pastedItems = try await FileOperationQueue.shared.copy(items: items, to: destination, undoManager: undoManager)
        }
        return pastedItems
    }

    private func finishSuccessfulCutPaste(owningPasteboardChangeCount: Int) {
        guard storedIsCut else { return }
        if pasteboard.changeCount == owningPasteboardChangeCount {
            clear()
            return
        }

        storedLocations = []
        storedCutItemLocations = []
        storedIsCut = false
        storedPasteboardChangeCount = pasteboard.changeCount
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    func clear() {
        pasteboard.clearContents()
        storedLocations = []
        storedIsCut = false
        storedCutItemLocations = []
        storedPasteboardChangeCount = pasteboard.changeCount
        NotificationCenter.default.post(name: Self.cutItemsDidChange, object: nil)
    }

    func isItemCut(_ url: URL) -> Bool {
        isItemCut(.local(url))
    }

    func isItemCut(_ location: Location) -> Bool {
        cutItemLocations.contains(location)
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
