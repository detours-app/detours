import AppKit
import Foundation

extension FileOperationQueue {
    // MARK: - Byte-Level Progress Polling

    struct BytePollContext {
        let destination: URL
        let operation: FileOperation
        let currentItem: URL
        let itemIndex: Int
        let itemCount: Int
        let bytesCopiedBefore: Int64
        let totalSize: Int64
    }

    /// Poll the destination file/folder size during a copy or move to report byte-level progress.
    /// Returns a cancellable task — cancel it when the I/O operation completes.
    func startBytePollTask(_ ctx: BytePollContext) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                guard !Task.isCancelled else { break }
                let currentDestSize = Self.calculateTotalSize(of: [ctx.destination])
                await MainActor.run { [weak self] in
                    self?.updateProgress(
                        operation: ctx.operation,
                        currentItem: ctx.currentItem,
                        completed: ctx.itemIndex,
                        total: ctx.itemCount,
                        bytesCompleted: ctx.bytesCopiedBefore + currentDestSize,
                        bytesTotal: ctx.totalSize
                    )
                }
            }
        }
    }

    // MARK: - Progress

    func startOperation(_ operation: FileOperation, totalCount: Int) {
        currentOperation = operation
        isCancelled = false
        lastProgressTime = 0

        // Fire onOperationStart FIRST so the UI switches to progress mode
        // before any progress updates arrive
        onOperationStart?(operation, totalCount)

        let progress = FileOperationProgress(
            operation: operation,
            currentItem: nil,
            completedCount: 0,
            totalCount: totalCount,
            bytesCompleted: 0,
            bytesTotal: 0
        )
        deliverProgress(progress)
    }

    func updateProgress(
        operation: FileOperation,
        currentItem: URL?,
        completed: Int,
        total: Int,
        bytesCompleted: Int64 = 0,
        bytesTotal: Int64 = 0
    ) {
        let progress = FileOperationProgress(
            operation: operation,
            currentItem: currentItem,
            completedCount: completed,
            totalCount: total,
            bytesCompleted: bytesCompleted,
            bytesTotal: bytesTotal
        )

        // Throttle UI updates to 16Hz (60ms intervals)
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastProgressTime

        if elapsed >= 0.060 {
            lastProgressTime = now
            pendingProgress = nil
            progressThrottleWorkItem?.cancel()
            progressThrottleWorkItem = nil
            deliverProgress(progress)
        } else {
            // Buffer and deliver after remaining interval
            pendingProgress = progress
            if progressThrottleWorkItem == nil {
                let delay = 0.060 - elapsed
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, let buffered = self.pendingProgress else { return }
                    self.lastProgressTime = CFAbsoluteTimeGetCurrent()
                    self.pendingProgress = nil
                    self.progressThrottleWorkItem = nil
                    self.deliverProgress(buffered)
                }
                progressThrottleWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }
    }

    private func deliverProgress(_ progress: FileOperationProgress) {
        lastReceivedProgress = progress
        onProgressUpdate?(progress)
    }

    func finishOperation() {
        lastFinishedOperation = currentOperation
        currentOperation = nil
        currentProcess = nil
        currentCancelFlag = nil
        lastReceivedProgress = nil
        progressThrottleWorkItem?.cancel()
        progressThrottleWorkItem = nil
        pendingProgress = nil
    }

    // MARK: - Helpers

    func checkCancelled() throws {
        if isCancelled {
            throw FileOperationError.cancelled
        }
    }

    /// Safely remove a temporary directory created by the app during extraction.
    /// SAFETY: This method refuses to delete any directory that wasn't created by Detours.
    /// Only directories with a `.detours-extract-` prefix OR directories that were explicitly
    /// created during this operation (tracked by the caller) are allowed.
    /// This prevents catastrophic deletion of user directories (e.g. ~/Downloads).
    static func removeAppCreatedDirectory(_ url: URL) {
        let name = url.lastPathComponent
        guard name.hasPrefix(".detours-extract-") else {
            // Not a temp dir we created — log and refuse to delete
            print("SAFETY: Refused to delete \(url.path) — not an app-created temp directory")
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    func recycle(item: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            NSWorkspace.shared.recycle([item]) { trashedURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let trashURL = trashedURLs[item] ?? trashedURLs.values.first {
                    // Fall back to first value in case of URL key mismatch (e.g. resolved symlinks)
                    continuation.resume(returning: trashURL)
                } else {
                    continuation.resume(throwing: FileOperationError.unknown(NSError(
                        domain: "Detours", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to get trash URL"]
                    )))
                }
            }
        }
    }

    /// Synchronous version of recycle for use in undo handlers
    /// Uses FileManager.trashItem which is truly synchronous (unlike NSWorkspace.recycle)
    nonisolated func recycleSync(items: [URL]) throws {
        let fileManager = FileManager.default
        for item in items {
            // trashItem is synchronous and doesn't require main thread callback
            try fileManager.trashItem(at: item, resultingItemURL: nil)
        }
    }

    /// Synchronous move for use in undo handlers
    nonisolated func moveSync(from source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func restoreFromTrash(items: [(original: URL, trash: URL)]) async throws {
        try restoreFromTrashSync(items: items)
    }

    func restoreRemoteTrashedItems(_ items: [TrashedItem]) async throws -> [Location] {
        var groups: [UUID: [TrashedItem]] = [:]
        for item in items {
            let hostID: UUID
            if case .remote(let trashHostID, _) = item.trashLocation {
                hostID = trashHostID
            } else if case .remote(let originalHostID, _) = item.originalLocation {
                hostID = originalHostID
            } else {
                throw FileProviderError.unsupportedOperation("Local trash restore must use the local restore path")
            }
            groups[hostID, default: []].append(item)
        }

        var restored: [Location] = []
        for (hostID, hostItems) in groups {
            let provider = try remoteProvider(for: hostID)
            restored.append(contentsOf: try await provider.restoreFromTrash(hostItems))
        }
        return restored
    }

    func restoreFromTrashSync(items: [(original: URL, trash: URL)]) throws {
        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []

        for item in items {
            do {
                // Check if trash file still exists
                guard fileManager.fileExists(atPath: item.trash.path) else {
                    throw FileOperationError.unknown(NSError(
                        domain: "Detours",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot restore \"\(item.original.lastPathComponent)\". The item is no longer in the Trash."]
                    ))
                }

                // Handle conflict if something now exists at original location
                var destination = item.original
                if fileManager.fileExists(atPath: destination.path) || isReserved(destination) {
                    destination = uniqueRestoreDestination(for: item.original)
                }

                // Reserve so a concurrent fast-lane pick cannot race this move
                reserveDestination(destination)
                do {
                    try fileManager.moveItem(at: item.trash, to: destination)
                    releaseDestination(destination)
                } catch {
                    releaseDestination(destination)
                    throw error
                }
            } catch {
                failures.append((item.original, mapError(error, url: item.original)))
            }
        }

        if !failures.isEmpty {
            if failures.count == items.count, let first = failures.first {
                throw first.1
            }
            throw FileOperationError.partialFailure(succeeded: [], failed: failures)
        }
    }

    private func uniqueRestoreDestination(for original: URL) -> URL {
        let fileManager = FileManager.default
        let directory = original.deletingLastPathComponent()
        let baseName = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension

        var attempt = 2
        while true {
            var name = "\(baseName) \(attempt)"
            if !ext.isEmpty {
                name += ".\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
                return candidate
            }
            attempt += 1
        }
    }

    func handleFailures(successes: [URL], failures: [(URL, Error)]) throws {
        if failures.isEmpty { return }
        if successes.isEmpty, let first = failures.first {
            if let error = first.1 as? FileOperationError {
                throw error
            }
            throw FileOperationError.unknown(first.1)
        }
        throw FileOperationError.partialFailure(succeeded: successes, failed: failures)
    }

    func mapError(_ error: Error, url: URL) -> FileOperationError {
        if let fileError = error as? FileOperationError {
            return fileError
        }

        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileNoSuchFile:
                return .sourceNotFound(url)
            case .fileWriteNoPermission, .fileReadNoPermission:
                return .permissionDenied(url)
            case .fileWriteOutOfSpace:
                return .diskFull
            default:
                break
            }
        }

        return .unknown(error)
    }

    private struct IncrementableYearName {
        private static let yearRegex = try? NSRegularExpression(pattern: #"(?<!\d)(19|20)\d{2}(?!\d)"#)

        let baseName: String
        let matchedRanges: [Range<String.Index>]
        let originalYear: Int

        init?(baseName: String) {
            guard let regex = Self.yearRegex else {
                return nil
            }

            let range = NSRange(baseName.startIndex..., in: baseName)
            let matches = regex.matches(in: baseName, range: range)
            let matchedRanges = matches.compactMap { Range($0.range, in: baseName) }
            guard !matchedRanges.isEmpty else {
                return nil
            }

            let matchedYears = matchedRanges.map { String(baseName[$0]) }
            guard let firstYear = matchedYears.first,
                  Set(matchedYears).count == 1,
                  let originalYear = Int(firstYear) else {
                return nil
            }

            self.baseName = baseName
            self.matchedRanges = matchedRanges
            self.originalYear = originalYear
        }

        func name(incrementedBy amount: Int) -> String {
            let replacement = String(originalYear + amount)
            var pieces: [String] = []
            var cursor = baseName.startIndex

            for range in matchedRanges {
                pieces.append(String(baseName[cursor..<range.lowerBound]))
                pieces.append(replacement)
                cursor = range.upperBound
            }

            pieces.append(String(baseName[cursor...]))
            return pieces.joined()
        }
    }

    func uniqueDuplicateDestination(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()

        if let yearIncrementedDestination = uniqueYearIncrementedDuplicateDestination(for: source, in: directory) {
            return yearIncrementedDestination
        }

        return uniqueCopyDestination(for: source, in: directory)
    }

    private func uniqueYearIncrementedDuplicateDestination(for source: URL, in directory: URL) -> URL? {
        let fileManager = FileManager.default
        let components = duplicateNameComponents(for: source)

        guard let incrementableName = IncrementableYearName(baseName: components.baseName) else {
            return nil
        }

        var attempt = 1
        while true {
            var name = incrementableName.name(incrementedBy: attempt)
            if !components.pathExtension.isEmpty {
                name += ".\(components.pathExtension)"
            }

            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
                return candidate
            }

            attempt += 1
        }
    }

    private func duplicateNameComponents(for source: URL) -> (baseName: String, pathExtension: String) {
        if let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           values.isDirectory == true,
           values.isPackage != true {
            return (source.lastPathComponent, "")
        }

        return (source.deletingPathExtension().lastPathComponent, source.pathExtension)
    }

    func isSameFilesystemPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func uniqueCopyDestination(for source: URL, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension

        var attempt = 1
        while true {
            let suffix = attempt == 1 ? " copy" : " copy \(attempt)"
            var name = baseName + suffix
            if !ext.isEmpty {
                name += ".\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
                return candidate
            }
            attempt += 1
        }
    }

    func uniqueFolderDestination(in directory: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        var attempt = 1

        while true {
            let name = attempt == 1 ? baseName : "\(baseName) \(attempt)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
                return candidate
            }
            attempt += 1
        }
    }

    func uniqueFileDestination(in directory: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        let nameWithoutExt = (baseName as NSString).deletingPathExtension
        let ext = (baseName as NSString).pathExtension
        var attempt = 1

        while true {
            let name: String
            if attempt == 1 {
                name = baseName
            } else if ext.isEmpty {
                name = "\(nameWithoutExt) \(attempt)"
            } else {
                name = "\(nameWithoutExt) \(attempt).\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
                return candidate
            }
            attempt += 1
        }
    }

    enum ConflictChoice {
        case skip
        case replace
        case keepBoth
    }

    struct ConflictResolution {
        let choice: ConflictChoice
        let applyToAll: Bool
    }

    func resolveConflict(
        source: URL,
        destination: URL,
        cachedChoice: ConflictChoice?
    ) async -> ConflictResolution {
        if isRunningTests {
            return ConflictResolution(choice: .keepBoth, applyToAll: true)
        }

        if let cachedChoice {
            return ConflictResolution(choice: cachedChoice, applyToAll: true)
        }

        let alert = NSAlert()
        alert.messageText = "Item Already Exists"
        alert.informativeText = "\"\(destination.lastPathComponent)\" already exists in \"\(destination.deletingLastPathComponent().lastPathComponent)\"."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")

        let applyToAllButton = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
        alert.accessoryView = applyToAllButton

        let response = alert.runModal()
        let choice: ConflictChoice
        switch response {
        case .alertFirstButtonReturn:
            choice = .keepBoth
        case .alertSecondButtonReturn:
            choice = .replace
        default:
            choice = .skip
        }

        return ConflictResolution(choice: choice, applyToAll: applyToAllButton.state == .on)
    }

    var isRunningTests: Bool {
        NSClassFromString("XCTest") != nil
    }
}
