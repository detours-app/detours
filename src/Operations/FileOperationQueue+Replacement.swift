import Foundation

struct LocalDisplacedItem: Sendable {
    let original: URL
    let trash: URL
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
        try await runFileIO {
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            guard let trashURL = trashURL as URL? else {
                throw FileOperationError.unknown(NSError(
                    domain: "Detours",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to record the Trash location for \"\(url.lastPathComponent)\"."]
                ))
            }
            return LocalDisplacedItem(original: url, trash: trashURL)
        }
    }

    func displaceLocalItemUntracked(_ url: URL) async throws -> LocalDisplacedItem {
        try await runUntrackedFileIO {
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            guard let trashURL = trashURL as URL? else {
                throw FileOperationError.unknown(NSError(
                    domain: "Detours",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to record the Trash location for \"\(url.lastPathComponent)\"."]
                ))
            }
            return LocalDisplacedItem(original: url, trash: trashURL)
        }
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
        if fileManager.fileExists(atPath: item.original.path) {
            try fileManager.trashItem(at: item.original, resultingItemURL: nil)
        }
        try fileManager.moveItem(at: item.trash, to: item.original)
    }

    nonisolated func undoLocalReplacementSync(
        createdItems: [URL],
        displacedItems: [LocalDisplacedItem]
    ) throws {
        for item in createdItems where FileManager.default.fileExists(atPath: item.path) {
            try FileManager.default.trashItem(at: item, resultingItemURL: nil)
        }
        for item in displacedItems.reversed() {
            try Self.restoreLocalDisplacementSync(item)
        }
    }

    func rollbackExtraction(_ ledger: ExtractionReplacementLedger) async throws {
        let createdItems = ledger.createdItems
        let displacedItems = ledger.displacedItems
        try await runFileIO {
            for item in createdItems.reversed() where FileManager.default.fileExists(atPath: item.path) {
                try FileManager.default.trashItem(at: item, resultingItemURL: nil)
            }
            for item in displacedItems.reversed() {
                try Self.restoreLocalDisplacementSync(item)
            }
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
