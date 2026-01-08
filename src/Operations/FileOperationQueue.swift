import AppKit
import Foundation

@MainActor
final class FileOperationQueue {
    static let shared = FileOperationQueue()

    private init() {}

    private(set) var currentOperation: FileOperation?
    var onProgressUpdate: ((FileOperationProgress) -> Void)?

    private var pending: [() async -> Void] = []
    private var isRunning = false
    private var isCancelled = false
    private var progressWindow: ProgressWindowController?

    // MARK: - Public API

    func copy(items: [URL], to destination: URL) async throws {
        try await enqueue {
            try await self.performCopy(items: items, to: destination)
        }
    }

    func move(items: [URL], to destination: URL) async throws {
        try await enqueue {
            try await self.performMove(items: items, to: destination)
        }
    }

    func delete(items: [URL]) async throws {
        try await enqueue {
            try await self.performDelete(items: items)
        }
    }

    func rename(item: URL, to newName: String) async throws -> URL {
        try await enqueue {
            try await self.performRename(item: item, to: newName)
        }
    }

    func duplicate(items: [URL]) async throws -> [URL] {
        try await enqueue {
            try await self.performDuplicate(items: items)
        }
    }

    func createFolder(in directory: URL, name: String) async throws -> URL {
        try await enqueue {
            try await self.performCreateFolder(in: directory, name: name)
        }
    }

    func cancelCurrentOperation() {
        isCancelled = true
    }

    func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning

        if let operationError = error as? FileOperationError {
            switch operationError {
            case .cancelled:
                return
            case let .partialFailure(_, failed):
                alert.messageText = "Some Items Failed"
                alert.informativeText = "\(failed.count) item\(failed.count == 1 ? "" : "s") failed. Check permissions and try again."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show Details")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    let detailAlert = NSAlert()
                    detailAlert.messageText = "Failed Items"
                    let lines = failed.map { $0.0.path }.joined(separator: "\n")
                    detailAlert.informativeText = lines
                    detailAlert.addButton(withTitle: "OK")
                    detailAlert.runModal()
                }
                return
            case let .permissionDenied(url):
                alert.messageText = "Permission Denied"
                alert.informativeText = "Permission denied for \"\(url.lastPathComponent)\". Check Full Disk Access in System Settings."
            default:
                alert.messageText = "Operation Failed"
                alert.informativeText = operationError.localizedDescription
            }
        } else {
            alert.messageText = "Operation Failed"
            alert.informativeText = error.localizedDescription
        }

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Queue

    private func enqueue<T>(_ work: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    let result = try await work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        pending.append(work)
        if !isRunning {
            processNext()
        }
    }

    private func processNext() {
        guard !pending.isEmpty else {
            isRunning = false
            return
        }

        isRunning = true
        let work = pending.removeFirst()

        Task { @MainActor in
            await work()
            processNext()
        }
    }

    // MARK: - Operations

    private func performCopy(items: [URL], to destination: URL) async throws {
        let operation = FileOperation.copy(sources: items, destination: destination)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [URL] = []
        var conflictChoice: ConflictChoice?

        for (index, source) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index,
                total: items.count
            )

            let targetDir = destination
            let initialDestination = targetDir.appendingPathComponent(source.lastPathComponent)
            let destinationURL: URL
            var skipped = false

            do {
                if fileManager.fileExists(atPath: initialDestination.path) {
                    let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                    if resolution.applyToAll {
                        conflictChoice = resolution.choice
                    }

                    switch resolution.choice {
                    case .skip:
                        skipped = true
                        destinationURL = initialDestination
                    case .replace:
                        try fileManager.removeItem(at: initialDestination)
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                    }
                } else {
                    destinationURL = initialDestination
                }

                if !skipped {
                    try fileManager.copyItem(at: source, to: destinationURL)
                    successes.append(destinationURL)
                }
            } catch {
                failures.append((source, mapError(error, url: source)))
            }

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index + 1,
                total: items.count
            )
        }

        try handleFailures(successes: successes, failures: failures)
    }

    private func performMove(items: [URL], to destination: URL) async throws {
        let operation = FileOperation.move(sources: items, destination: destination)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [URL] = []
        var conflictChoice: ConflictChoice?

        for (index, source) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index,
                total: items.count
            )

            let targetDir = destination
            let initialDestination = targetDir.appendingPathComponent(source.lastPathComponent)
            let destinationURL: URL
            var skipped = false

            do {
                if fileManager.fileExists(atPath: initialDestination.path) {
                    let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                    if resolution.applyToAll {
                        conflictChoice = resolution.choice
                    }

                    switch resolution.choice {
                    case .skip:
                        skipped = true
                        destinationURL = initialDestination
                    case .replace:
                        try fileManager.removeItem(at: initialDestination)
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                    }
                } else {
                    destinationURL = initialDestination
                }

                if !skipped {
                    try fileManager.moveItem(at: source, to: destinationURL)
                    successes.append(destinationURL)
                }
            } catch {
                failures.append((source, mapError(error, url: source)))
            }

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index + 1,
                total: items.count
            )
        }

        try handleFailures(successes: successes, failures: failures)
    }

    private func performDelete(items: [URL]) async throws {
        let operation = FileOperation.delete(items: items)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        var failures: [(URL, Error)] = []
        var successes: [URL] = []

        for (index, item) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: item,
                completed: index,
                total: items.count
            )

            do {
                try await recycle(item: item)
                successes.append(item)
            } catch {
                failures.append((item, mapError(error, url: item)))
            }

            updateProgress(
                operation: operation,
                currentItem: item,
                completed: index + 1,
                total: items.count
            )
        }

        try handleFailures(successes: successes, failures: failures)
    }

    private func performRename(item: URL, to newName: String) async throws -> URL {
        let operation = FileOperation.rename(item: item, newName: newName)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let invalidChars = CharacterSet(charactersIn: ":/")
        if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileOperationError.unknown(NSError(domain: "Detours", code: 1, userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty."]))
        }

        if newName.rangeOfCharacter(from: invalidChars) != nil {
            throw FileOperationError.unknown(NSError(domain: "Detours", code: 1, userInfo: [NSLocalizedDescriptionKey: "Name contains invalid characters."]))
        }

        let destination = item.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw FileOperationError.destinationExists(destination)
        }

        do {
            try FileManager.default.moveItem(at: item, to: destination)
            updateProgress(operation: operation, currentItem: item, completed: 1, total: 1)
            return destination
        } catch {
            throw mapError(error, url: item)
        }
    }

    private func performDuplicate(items: [URL]) async throws -> [URL] {
        let operation = FileOperation.duplicate(items: items)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [URL] = []

        for (index, source) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index,
                total: items.count
            )

            do {
                let destination = uniqueCopyDestination(for: source, in: source.deletingLastPathComponent())
                try fileManager.copyItem(at: source, to: destination)
                successes.append(destination)
            } catch {
                failures.append((source, mapError(error, url: source)))
            }

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index + 1,
                total: items.count
            )
        }

        try handleFailures(successes: successes, failures: failures)
        return successes
    }

    private func performCreateFolder(in directory: URL, name: String) async throws -> URL {
        let operation = FileOperation.createFolder(directory: directory, name: name)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let destination = uniqueFolderDestination(in: directory, baseName: name)

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: nil)
            updateProgress(operation: operation, currentItem: destination, completed: 1, total: 1)
            return destination
        } catch {
            throw mapError(error, url: destination)
        }
    }

    // MARK: - Progress

    private func startOperation(_ operation: FileOperation, totalCount: Int) {
        currentOperation = operation
        isCancelled = false

        let progress = FileOperationProgress(
            operation: operation,
            currentItem: nil,
            completedCount: 0,
            totalCount: totalCount,
            bytesCompleted: 0,
            bytesTotal: 0
        )
        onProgressUpdate?(progress)

        if totalCount > 5 {
            showProgress(progress)
        }
    }

    private func updateProgress(operation: FileOperation, currentItem: URL?, completed: Int, total: Int) {
        let progress = FileOperationProgress(
            operation: operation,
            currentItem: currentItem,
            completedCount: completed,
            totalCount: total,
            bytesCompleted: 0,
            bytesTotal: 0
        )
        onProgressUpdate?(progress)
        progressWindow?.update(progress)
    }

    private func finishOperation() {
        currentOperation = nil
        progressWindow?.dismiss()
        progressWindow = nil
    }

    private func showProgress(_ progress: FileOperationProgress) {
        guard let window = NSApp.keyWindow else { return }
        let controller = ProgressWindowController(progress: progress) { [weak self] in
            self?.cancelCurrentOperation()
        }
        controller.show(over: window)
        progressWindow = controller
    }

    // MARK: - Helpers

    private func checkCancelled() throws {
        if isCancelled {
            throw FileOperationError.cancelled
        }
    }

    private func recycle(item: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([item]) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func handleFailures(successes: [URL], failures: [(URL, Error)]) throws {
        if failures.isEmpty { return }
        if successes.isEmpty, let first = failures.first {
            if let error = first.1 as? FileOperationError {
                throw error
            }
            throw FileOperationError.unknown(first.1)
        }
        throw FileOperationError.partialFailure(succeeded: successes, failed: failures)
    }

    private func mapError(_ error: Error, url: URL) -> FileOperationError {
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

    private func uniqueCopyDestination(for source: URL, in directory: URL) -> URL {
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
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private func uniqueFolderDestination(in directory: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        var attempt = 1

        while true {
            let name = attempt == 1 ? baseName : "\(baseName) \(attempt)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private enum ConflictChoice {
        case skip
        case replace
        case keepBoth
    }

    private struct ConflictResolution {
        let choice: ConflictChoice
        let applyToAll: Bool
    }

    private func resolveConflict(
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

    private var isRunningTests: Bool {
        NSClassFromString("XCTest") != nil
    }
}
