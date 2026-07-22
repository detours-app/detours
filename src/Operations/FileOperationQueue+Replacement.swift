import Foundation

struct LocalDisplacedItem: Sendable {
    enum Storage: Sendable, Equatable {
        case trash
        case fallback
    }

    let original: URL
    let trash: URL
    let storage: Storage
}

enum ProviderMoveSourceRestore: Sendable {
    case local(LocalDisplacedItem)
    case remote(TrashedItem)
}

@MainActor
final class ExtractionReplacementLedger {
    var displacedItems: [LocalDisplacedItem] = []
    var createdItems: [URL] = []
}

extension FileOperationQueue {
    nonisolated func replacementRollbackError(
        operationError: any Error,
        rollbackError: any Error
    ) -> any Error {
        NSError(
            domain: "Detours.ReplaceRollback",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operationError.localizedDescription) The original item could not be restored: " +
                    rollbackError.localizedDescription
            ]
        )
    }

    func displaceLocalItem(_ url: URL) async throws -> LocalDisplacedItem {
        #if DEBUG
        let forceFallback = forceLocalDisplacementFallbackForTesting
        #else
        let forceFallback = false
        #endif
        return try await runFileIO {
            try Self.displaceLocalItemSync(url, forceFallback: forceFallback)
        }
    }

    func displaceLocalItemUntracked(_ url: URL) async throws -> LocalDisplacedItem {
        #if DEBUG
        let forceFallback = forceLocalDisplacementFallbackForTesting
        #else
        let forceFallback = false
        #endif
        return try await runUntrackedFileIO {
            try Self.displaceLocalItemSync(url, forceFallback: forceFallback)
        }
    }

    nonisolated static func displaceLocalItemSync(
        _ url: URL,
        forceFallback: Bool = false
    ) throws -> LocalDisplacedItem {
        let fileManager = FileManager.default
        if !forceFallback {
            var trashURL: NSURL?
            do {
                try fileManager.trashItem(at: url, resultingItemURL: &trashURL)
                if let trashURL = trashURL as URL? {
                    return LocalDisplacedItem(original: url, trash: trashURL, storage: .trash)
                }
            } catch {
                // SMB and some removable volumes do not implement Finder Trash.
                // Keep the displaced item beside its destination until commit or
                // undo so replacement remains rollback-safe on those volumes.
            }
        }

        let fallbackURL = url.deletingLastPathComponent().appendingPathComponent(
            ".detours-replacement-\(UUID().uuidString.lowercased())-\(url.lastPathComponent)"
        )
        try fileManager.moveItem(at: url, to: fallbackURL)
        return LocalDisplacedItem(original: url, trash: fallbackURL, storage: .fallback)
    }

    func rollbackLocalDisplacement(_ item: LocalDisplacedItem) async throws {
        try await runFileIO {
            try Self.restoreLocalDisplacementSync(item)
        }
    }

    func rollbackLocalDisplacementUntracked(_ item: LocalDisplacedItem) async throws {
        try await runUntrackedFileIO {
            try Self.restoreLocalDisplacementSync(item)
        }
    }

    nonisolated static func restoreLocalDisplacementSync(_ item: LocalDisplacedItem) throws {
        let fileManager = FileManager.default
        var displacedCurrent: LocalDisplacedItem?
        if fileManager.fileExists(atPath: item.original.path) {
            displacedCurrent = try displaceLocalItemSync(
                item.original,
                forceFallback: item.storage == .fallback
            )
        }
        do {
            try fileManager.moveItem(at: item.trash, to: item.original)
        } catch {
            if let displacedCurrent,
               !fileManager.fileExists(atPath: item.original.path) {
                try? fileManager.moveItem(at: displacedCurrent.trash, to: item.original)
            }
            throw error
        }
        if let displacedCurrent, displacedCurrent.storage == .fallback {
            try fileManager.removeItem(at: displacedCurrent.trash)
        }
    }

    func finalizeLocalDisplacements(_ items: [LocalDisplacedItem]) async throws {
        let fallbackURLs = items.filter { $0.storage == .fallback }.map(\.trash)
        guard !fallbackURLs.isEmpty else { return }
        try await runFileIO {
            for url in fallbackURLs where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func finalizeLocalDisplacementsUntracked(_ items: [LocalDisplacedItem]) async throws {
        let fallbackURLs = items.filter { $0.storage == .fallback }.map(\.trash)
        guard !fallbackURLs.isEmpty else { return }
        try await runUntrackedFileIO {
            for url in fallbackURLs where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    nonisolated func undoLocalReplacementSync(
        createdItems: [URL],
        displacedItems: [LocalDisplacedItem]
    ) throws {
        try Self.replaceCreatedItemsWithDisplacementsSync(
            createdItems: createdItems,
            displacedItems: displacedItems
        )
    }

    nonisolated static func replaceCreatedItemsWithDisplacementsSync(
        createdItems: [URL],
        displacedItems: [LocalDisplacedItem]
    ) throws {
        let fileManager = FileManager.default
        var removedCreatedItems: [LocalDisplacedItem] = []
        let keepDisplacementsContained = displacedItems.contains { $0.storage == .fallback }
        do {
            for item in createdItems where fileManager.fileExists(atPath: item.path) {
                removedCreatedItems.append(try displaceLocalItemSync(
                    item,
                    forceFallback: keepDisplacementsContained
                ))
            }
            for item in displacedItems.reversed() {
                try restoreLocalDisplacementSync(item)
            }
            for item in removedCreatedItems
            where item.storage == .fallback && fileManager.fileExists(atPath: item.trash.path) {
                try fileManager.removeItem(at: item.trash)
            }
        } catch {
            for item in removedCreatedItems.reversed()
            where !fileManager.fileExists(atPath: item.original.path)
                && fileManager.fileExists(atPath: item.trash.path) {
                try? fileManager.moveItem(at: item.trash, to: item.original)
            }
            throw error
        }
    }

    func rollbackExtraction(_ ledger: ExtractionReplacementLedger) async throws {
        let createdItems = ledger.createdItems
        let displacedItems = ledger.displacedItems
        try await runFileIO {
            try Self.replaceCreatedItemsWithDisplacementsSync(
                createdItems: Array(createdItems.reversed()),
                displacedItems: displacedItems
            )
        }
    }

    func registerExtractionUndo(
        ledger: ExtractionReplacementLedger,
        archive: URL,
        undoManager: UndoManager?
    ) {
        guard let undoManager, !ledger.createdItems.isEmpty else { return }
        let createdItems = ledger.createdItems
        let displacedItems = ledger.displacedItems
        undoManager.registerUndo(withTarget: self) { target in
            do {
                try target.undoLocalReplacementSync(
                    createdItems: createdItems,
                    displacedItems: displacedItems
                )
            } catch {
                target.presentError(error)
            }
        }
        undoManager.setActionName("Extract \"\(archive.lastPathComponent)\"")
    }
}
