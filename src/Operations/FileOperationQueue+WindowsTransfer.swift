import AppKit
import Foundation

extension FileOperationQueue {
    /// The provider and direction shared by every step of one Windows transfer.
    struct WindowsTransferContext {
        let provider: WindowsRemoteProvider
        let isMove: Bool
    }

    /// Records what a Windows conflict-aware copy/move placed so undo can reverse it.
    final class WindowsTransferLedger {
        var placed: [(placed: Location, source: Location)] = []
        var displacedTokens: [TrashedItem] = []
        var movedSourceFolders: [TrashedItem] = []
    }

    /// Windows same-host copy/move that resolves same-name collisions through the shared
    /// Skip/Replace/Keep Both flow, merges folders, replaces failure-safely, and registers
    /// an undo that restores any displaced original. Mirrors the local copy/move semantics.
    func performWindowsTransfer(
        items: [Location],
        to destination: Location,
        provider: WindowsRemoteProvider,
        isMove: Bool,
        undoManager: UndoManager?
    ) async throws -> [Location] {
        let context = WindowsTransferContext(provider: provider, isMove: isMove)
        let urls = items.map { URL(fileURLWithPath: $0.path) }
        let destinationURL = URL(fileURLWithPath: destination.path)
        let operation = isMove
            ? FileOperation.move(sources: urls, destination: destinationURL)
            : FileOperation.copy(sources: urls, destination: destinationURL)
        let ledger = WindowsTransferLedger()
        let hostName = await transferHostName(for: destination)
        var conflictChoice: ConflictChoice?
        var failures: [(URL, Error)] = []

        for (index, source) in items.enumerated() {
            try checkCancelled()
            let displayURL = URL(fileURLWithPath: source.path)
            updateProgress(operation: operation, currentItem: displayURL, completed: index, total: items.count)
            do {
                try await windowsPlaceItem(source: source, into: destination, context: context, conflictChoice: &conflictChoice, ledger: ledger)
            } catch {
                failures.append((displayURL, RemoteOperationError.operation(
                    action: isMove ? .move : .copy,
                    item: displayURL.lastPathComponent,
                    host: hostName,
                    underlying: error
                )))
            }
            updateProgress(operation: operation, currentItem: displayURL, completed: index + 1, total: items.count)
        }

        let placed = ledger.placed.map(\.placed)
        if failures.isEmpty, !placed.isEmpty, let undoManager {
            registerWindowsTransferUndo(undoManager: undoManager, context: context, ledger: ledger, hostName: hostName)
        }
        try handleFailures(successes: placed.map { URL(fileURLWithPath: $0.path) }, failures: failures)
        return placed
    }

    private func windowsPlaceItem(
        source: Location,
        into destination: Location,
        context: WindowsTransferContext,
        conflictChoice: inout ConflictChoice?,
        ledger: WindowsTransferLedger
    ) async throws {
        let provider = context.provider
        let isMove = context.isMove
        let target = destination.appendingPathComponent(source.lastPathComponent)
        guard let existing = try? await provider.stat(target) else {
            // No collision: place the item at its target name directly.
            let placed = isMove
                ? try await provider.moveItem(source, to: target)
                : try await provider.copyItem(source, to: target)
            ledger.placed.append((placed, source))
            return
        }

        let sourceEntry = try await provider.stat(source)
        if sourceEntry.isDirectory, existing.isDirectory {
            // Folder onto an existing same-name folder merges (Finder-style): descend and
            // resolve each child rather than discarding the existing folder.
            let children = try await provider.list(source, showHidden: true)
            for child in children {
                try await windowsPlaceItem(source: child.location, into: target, context: context, conflictChoice: &conflictChoice, ledger: ledger)
            }
            if isMove, let token = try await provider.trash([source]).first {
                // The source folder's children moved out; trash the now-empty source so undo
                // can restore it and move the children back into it.
                ledger.movedSourceFolders.append(token)
            }
            return
        }

        let resolution = await resolveConflict(
            source: URL(fileURLWithPath: source.path),
            destination: URL(fileURLWithPath: target.path),
            cachedChoice: conflictChoice
        )
        if resolution.applyToAll { conflictChoice = resolution.choice }

        switch resolution.choice {
        case .skip:
            return
        case .keepBoth:
            let unique = try await uniqueDestinationLocation(for: source, in: destination, provider: provider)
            let placed = isMove
                ? try await provider.moveItem(source, to: unique)
                : try await provider.copyItem(source, to: unique)
            ledger.placed.append((placed, source))
        case .replace:
            let token = try await windowsReplace(source: source, target: target, into: destination, context: context)
            ledger.placed.append((target, source))
            ledger.displacedTokens.append(token)
        }
    }

    /// Failure-safe replace: stage the new item under a temporary name, displace the
    /// existing target to the host trash only after the new content is in place, then swap
    /// names. On any failure the original is left intact or recoverable via the returned token.
    private func windowsReplace(
        source: Location,
        target: Location,
        into destination: Location,
        context: WindowsTransferContext
    ) async throws -> TrashedItem {
        let provider = context.provider
        let tempName = ".detours-replace-\(UUID().uuidString)-\(target.lastPathComponent)"
        let tempTarget = destination.appendingPathComponent(tempName)
        _ = context.isMove
            ? try await provider.moveItem(source, to: tempTarget)
            : try await provider.copyItem(source, to: tempTarget)
        var displaced: TrashedItem?
        do {
            guard let token = try await provider.trash([target]).first else {
                throw FileProviderError.unsupportedOperation("Windows replace produced no restore token")
            }
            displaced = token
            #if DEBUG
            if windowsReplacementFailureProbeForTesting?() == true {
                throw CancellationError()
            }
            #endif
            _ = try await provider.rename(tempTarget, to: target.lastPathComponent)
            return token
        } catch {
            var reportedError = error
            if let displaced {
                do {
                    _ = try await provider.restoreFromTrash([displaced])
                } catch {
                    reportedError = replacementRollbackError(
                        operationError: reportedError,
                        rollbackError: error
                    )
                }
            }
            do {
                if context.isMove {
                    _ = try await provider.moveItem(tempTarget, to: source)
                } else {
                    _ = try await provider.trash([tempTarget])
                }
            } catch {
                reportedError = replacementRollbackError(
                    operationError: reportedError,
                    rollbackError: error
                )
            }
            throw reportedError
        }
    }

    private func registerWindowsTransferUndo(
        undoManager: UndoManager,
        context: WindowsTransferContext,
        ledger: WindowsTransferLedger,
        hostName: String
    ) {
        let provider = context.provider
        let isMove = context.isMove
        let placedPairs = ledger.placed
        let displacedTokens = ledger.displacedTokens
        let movedSourceFolders = ledger.movedSourceFolders
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                do {
                    // 1. Restore emptied source folders (move-merge) so children have a home.
                    if !movedSourceFolders.isEmpty {
                        _ = try await provider.restoreFromTrash(movedSourceFolders)
                    }
                    // 2. Reverse each placement: move-back for moves, trash for copies.
                    if isMove {
                        for pair in placedPairs {
                            _ = try await provider.moveItem(pair.placed, to: pair.source)
                        }
                    } else {
                        _ = try await provider.trash(placedPairs.map(\.placed))
                    }
                    // 3. Restore displaced originals (Replace) to their original paths.
                    if !displacedTokens.isEmpty {
                        _ = try await provider.restoreFromTrash(displacedTokens)
                    }
                } catch {
                    target.presentError(RemoteOperationError.undo(host: hostName, underlying: error))
                }
            }
        }
        let placed = ledger.placed.map(\.placed)
        let firstName = placed.first?.lastPathComponent ?? ""
        let actionName = placed.count == 1
            ? "\(isMove ? "Move" : "Copy") \"\(firstName)\""
            : "\(isMove ? "Move" : "Copy") \(placed.count) Items"
        undoManager.setActionName(actionName)
    }
}
