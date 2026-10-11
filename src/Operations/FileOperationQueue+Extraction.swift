import AppKit
import DetoursProcess
import Foundation

extension FileOperationQueue {
    func performExtract(
        archive: URL,
        password: String?,
        undoManager: UndoManager?,
        onRarParts: (([Location]) -> Void)? = nil
    ) async throws -> URL {
        guard let format = ArchiveFormat.detect(from: archive) ?? (RarVolumeSet.isCandidate(archive.lastPathComponent) ? .rar : nil) else {
            throw FileOperationError.archiveExtractionFailed("Unsupported archive format: \(archive.pathExtension)")
        }
        if let password, !password.isEmpty {
            guard format.supportsPassword else {
                throw FileOperationError.archivePasswordInvalid("\(format.displayName) does not support passwords")
            }
            try ArchivePasswordValidation.validate(password, format: format)
        }

        let ledger = ExtractionReplacementLedger()
        do {
            let result: URL
            switch format {
            case .rar:
                result = try await performExtractRar(archive: archive, password: password, ledger: ledger, onRarParts: onRarParts)
            case .zip:
                result = try await performExtractZip(
                    archive: archive,
                    format: format,
                    password: password,
                    ledger: ledger
                )
            case .sevenZ:
                if let password, !password.isEmpty {
                    result = try await performExtractEncryptedSevenZip(
                        archive: archive,
                        password: password,
                        ledger: ledger
                    )
                } else {
                    result = try await performExtractNonZip(
                        archive: archive,
                        format: format,
                        ledger: ledger
                    )
                }
            case .tarGz, .tarBz2, .tarXz:
                result = try await performExtractNonZip(
                    archive: archive,
                    format: format,
                    ledger: ledger
                )
            }
            if undoManager != nil {
                registerExtractionUndo(ledger: ledger, archive: archive, undoManager: undoManager)
            } else {
                try await finalizeLocalDisplacements(ledger.displacedItems)
            }
            return result
        } catch {
            let extractionError = error
            guard !ledger.displacedItems.isEmpty || !ledger.createdItems.isEmpty else {
                throw extractionError
            }
            do {
                try await rollbackExtraction(ledger)
            } catch {
                throw replacementRollbackError(
                    operationError: extractionError,
                    rollbackError: error
                )
            }
            throw extractionError
        }
    }

    // MARK: - ZIP Extraction (ditto)

    /// Extract ZIP archives using ditto. Extracts to a temp dir first to discover
    /// actual filenames (avoids encoding issues with unzip -Z1), then moves results
    /// into place with proper conflict handling.
    private func performExtractZip(
        archive: URL,
        format: ArchiveFormat,
        password: String?,
        ledger: ExtractionReplacementLedger
    ) async throws -> URL {
        let operation = FileOperation.extract(archive: archive, format: format)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let metadata = try? await runFileIO {
            try ZipArchiveMetadata.read(from: archive)
        }
        if metadata?.isEncrypted == true, password?.isEmpty != false {
            throw FileOperationError.archivePasswordRequired
        }

        let parentDir = archive.deletingLastPathComponent()
        let fileManager = FileManager.default

        enterProtectedPaths([archive, parentDir])
        defer { leaveProtectedPaths([archive, parentDir]) }

        // Create temp dir for extraction
        let tempDir = parentDir.appendingPathComponent(".detours-extract-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            Self.removeAppCreatedDirectory(tempDir)
        }

        try checkCancelled()
        try await validateZipMemberPaths(archive: archive)

        if metadata?.requiresSevenZip == true {
            try await extractZipWithSevenZip(
                archive: archive,
                destination: tempDir,
                password: password
            )
        } else if let password, !password.isEmpty {
            try await extractZipWithPassword(archive: archive, destination: tempDir, password: password)
        } else {
            try await extractZipWithDitto(archive: archive, destination: tempDir)
        }

        // Scan temp dir for top-level items (real filenames from the filesystem, no encoding issues)
        let extractedItems = try fileManager.contentsOfDirectory(atPath: tempDir.path)
            .filter { !$0.hasPrefix(".") }

        guard !extractedItems.isEmpty else {
            throw FileOperationError.archiveExtractionFailed("Archive appears to be empty")
        }

        let resultURL: URL

        if extractedItems.count > 1 {
            // Multiple top-level items — create wrapper folder named after the zip
            var wrapperName = archive.deletingPathExtension().lastPathComponent
            if wrapperName.hasSuffix(".tar") {
                wrapperName = String(wrapperName.dropLast(4))
            }
            var wrapperURL = parentDir.appendingPathComponent(wrapperName)

            if fileManager.fileExists(atPath: wrapperURL.path) {
                let choice = await resolveExtractConflict(
                    conflictingItems: [wrapperName],
                    destination: parentDir
                )
                switch choice {
                case .replace:
                    ledger.displacedItems.append(try await displaceLocalItem(wrapperURL))
                case .keepBoth:
                    wrapperURL = uniqueCopyDestination(for: wrapperURL, in: parentDir)
                case .stop:
                    throw FileOperationError.cancelled
                }
            }

            try fileManager.createDirectory(at: wrapperURL, withIntermediateDirectories: true)
            ledger.createdItems.append(wrapperURL)

            // Move all extracted items into wrapper
            for item in extractedItems {
                let src = tempDir.appendingPathComponent(item)
                let dst = wrapperURL.appendingPathComponent(item)
                try fileManager.moveItem(at: src, to: dst)
            }

            resultURL = wrapperURL
        } else {
            // Single top-level item — move to parent, renamed to match the zip filename
            let itemName = extractedItems[0]
            let src = tempDir.appendingPathComponent(itemName)

            // Use the zip's name (without extension) for the extracted item when it's a folder,
            // so "Entscheid GGSt Bachwiesstr.zip" extracts to "Entscheid GGSt Bachwiesstr/"
            // regardless of what the internal folder is called
            let isDirectory = (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let destName: String
            if isDirectory {
                destName = archive.deletingPathExtension().lastPathComponent
            } else {
                destName = itemName
            }
            var dst = parentDir.appendingPathComponent(destName)

            if fileManager.fileExists(atPath: dst.path) {
                // Don't prompt conflict if the existing item IS the archive itself
                if dst.path != archive.path {
                    let choice = await resolveExtractConflict(
                        conflictingItems: [destName],
                        destination: parentDir
                    )
                    switch choice {
                    case .replace:
                        ledger.displacedItems.append(try await displaceLocalItem(dst))
                    case .keepBoth:
                        dst = uniqueCopyDestination(for: dst, in: parentDir)
                    case .stop:
                        throw FileOperationError.cancelled
                    }
                } else {
                    dst = uniqueCopyDestination(for: dst, in: parentDir)
                }
            }

            try fileManager.moveItem(at: src, to: dst)
            ledger.createdItems.append(dst)
            resultURL = dst
        }

        updateProgress(operation: operation, currentItem: resultURL, completed: 1, total: 1)
        return resultURL
    }

    /// Extract ZIP with ditto (non-encrypted)
    private func extractZipWithDitto(archive: URL, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.ditto.path)
        process.arguments = ["-xk", archive.path, destination.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        // Use archive size as rough progress indicator — extracted data is larger,
        // but the progress bar will fill and then hold at ~100% until complete
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let mode: ArchiveProgressMode = archiveSize > 0 ? .pollFileSize(sourceSize: archiveSize * 3) : .none
        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: true, progressMode: mode)
    }

    private func extractZipWithPassword(
        archive: URL,
        destination: URL,
        password: String
    ) async throws {
        try ArchivePasswordValidation.validate(password, format: .zip)
        let invocation = PtyProcessInvocation(
            executable: CompressionTool.unzip.path,
            arguments: ["-o", "-q", archive.path, "-d", destination.path],
            password: password,
            responses: [.password, .empty],
            minimumResponses: 1
        )
        let runnerTask = Task {
            try await PtyProcessRunner().run(invocation)
        }
        currentIOCancellable = AnyCancellableTask(runnerTask)
        defer { currentIOCancellable = nil }

        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let progressTask = startEncryptedExtractionSizePolling(
            destination: destination,
            expectedSize: archiveSize * 3
        )
        defer { progressTask.cancel() }

        do {
            let result = try await runnerTask.value
            try checkCancelled()
            guard result.status == 0 else {
                let diagnostic = result.outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isZipPasswordFailure(diagnostic, status: result.status) {
                    throw FileOperationError.archivePasswordRequired
                }
                let message = diagnostic.isEmpty ? "Process exited with code \(result.status)" : diagnostic
                throw FileOperationError.archiveExtractionFailed(message)
            }
        } catch is CancellationError {
            throw FileOperationError.cancelled
        }
    }

    private func extractZipWithSevenZip(
        archive: URL,
        destination: URL,
        password: String?
    ) async throws {
        guard CompressionTools.isAvailable(.sevenZip) else {
            throw FileOperationError.archiveToolNotFound(CompressionTool.sevenZip.displayName)
        }
        if let password, !password.isEmpty {
            let invocation = PtyProcessInvocation(
                executable: CompressionTool.sevenZip.path,
                arguments: ["x", "-y", "-bsp2", "-o\(destination.path)", archive.path],
                password: password,
                responses: [.password],
                minimumResponses: 1,
                passwordEchoPolicy: sevenZipPasswordEchoPolicy
            )
            let result = try await runArchivePty(invocation)
            guard result.status == 0 else {
                throw Self.sevenZipFailure(result)
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)
        process.arguments = ["x", "-y", "-bsp2", "-o\(destination.path)", archive.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        try await runExtractProcess(
            process,
            errorPipe: errorPipe,
            destination: destination,
            passwordProtected: false,
            progressMode: .parseStderr(referenceSize: archiveSize)
        )
    }

    private func startEncryptedExtractionSizePolling(
        destination: URL,
        expectedSize: Int64
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard expectedSize > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, let operation = self.currentOperation else { return }
                self.updateProgress(
                    operation: operation,
                    currentItem: destination,
                    completed: 0,
                    total: 0,
                    bytesCompleted: Self.directorySize(at: destination),
                    bytesTotal: expectedSize
                )
            }
        }
    }

    nonisolated static func isZipPasswordFailure(_ message: String, status: Int32) -> Bool {
        ArchiveToolDiagnostics.isZipPasswordFailure(message: message, status: status)
    }

    // MARK: - Password-protected 7Z extraction

    private func performExtractEncryptedSevenZip(
        archive: URL,
        password: String,
        ledger: ExtractionReplacementLedger
    ) async throws -> URL {
        let format = ArchiveFormat.sevenZ
        let operation = FileOperation.extract(archive: archive, format: format)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        guard CompressionTools.canExtract(format) else {
            throw FileOperationError.archiveToolNotFound(CompressionTool.sevenZip.displayName)
        }

        let parentDirectory = archive.deletingLastPathComponent()
        enterProtectedPaths([archive, parentDirectory])
        defer { leaveProtectedPaths([archive, parentDirectory]) }

        let temporaryDirectory = parentDirectory.appendingPathComponent(".detours-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { Self.removeAppCreatedDirectory(temporaryDirectory) }

        try checkCancelled()
        _ = try await listEncryptedSevenZip(archive: archive, password: password)
        try await extractEncryptedSevenZip(
            archive: archive,
            destination: temporaryDirectory,
            password: password
        )

        let result = try await materialiseEncryptedSevenZip(
            temporaryDirectory: temporaryDirectory,
            archive: archive,
            ledger: ledger
        )
        updateProgress(operation: operation, currentItem: result, completed: 1, total: 1)
        return result
    }

    private func listEncryptedSevenZip(archive: URL, password: String) async throws -> Set<String> {
        let invocation = PtyProcessInvocation(
            executable: CompressionTool.sevenZip.path,
            arguments: ["l", "-slt", archive.path],
            password: password,
            responses: [.password],
            minimumResponses: 1,
            passwordEchoPolicy: sevenZipPasswordEchoPolicy
        )
        let result = try await runArchivePty(invocation)
        guard result.status == 0 else {
            throw Self.sevenZipFailure(result)
        }
        try Self.validateMemberPaths(
            Self.sevenZipListingMemberPaths(result.outputString, requireSeparator: true)
        )
        return Self.parseSevenZipTopLevelEntries(result.outputString)
    }

    private func extractEncryptedSevenZip(
        archive: URL,
        destination: URL,
        password: String
    ) async throws {
        let invocation = PtyProcessInvocation(
            executable: CompressionTool.sevenZip.path,
            arguments: ["x", "-y", "-bsp2", "-o\(destination.path)", archive.path],
            password: password,
            responses: [.password],
            minimumResponses: 1,
            passwordEchoPolicy: sevenZipPasswordEchoPolicy
        )
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let parser = ArchivePercentageParser()
        let result = try await runArchivePty(invocation) { [weak self] data in
            guard let percent = parser.consume(data) else { return }
            Task { @MainActor [weak self] in
                guard let self, let operation = self.currentOperation else { return }
                let fraction = min(Double(percent) / 100, 1)
                self.updateProgress(
                    operation: operation,
                    currentItem: destination,
                    completed: 0,
                    total: 0,
                    bytesCompleted: Int64(Double(archiveSize) * fraction),
                    bytesTotal: archiveSize
                )
            }
        }
        guard result.status == 0 else {
            throw Self.sevenZipFailure(result)
        }
    }

    private func runArchivePty(
        _ invocation: PtyProcessInvocation,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws -> PtyProcessResult {
        let runnerTask = Task {
            try await PtyProcessRunner().run(invocation, onOutput: onOutput)
        }
        currentIOCancellable = AnyCancellableTask(runnerTask)
        defer { currentIOCancellable = nil }
        do {
            let result = try await runnerTask.value
            try checkCancelled()
            return result
        } catch is CancellationError {
            throw FileOperationError.cancelled
        }
    }

    private func materialiseEncryptedSevenZip(
        temporaryDirectory: URL,
        archive: URL,
        ledger: ExtractionReplacementLedger
    ) async throws -> URL {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard !items.isEmpty else {
            throw FileOperationError.archiveExtractionFailed("Archive appears to be empty")
        }

        let parentDirectory = archive.deletingLastPathComponent()
        if items.count == 1, let item = items.first {
            var destination = parentDirectory.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                switch await resolveExtractConflict(
                    conflictingItems: [destination.lastPathComponent],
                    destination: parentDirectory
                ) {
                case .replace:
                    ledger.displacedItems.append(try await displaceLocalItem(destination))
                case .keepBoth:
                    destination = uniqueCopyDestination(for: destination, in: parentDirectory)
                case .stop:
                    throw FileOperationError.cancelled
                }
            }
            try fileManager.moveItem(at: item, to: destination)
            ledger.createdItems.append(destination)
            return destination
        }

        var wrapperName = archive.deletingPathExtension().lastPathComponent
        if wrapperName.hasSuffix(".tar") {
            wrapperName = String(wrapperName.dropLast(4))
        }
        var wrapper = parentDirectory.appendingPathComponent(wrapperName)
        if fileManager.fileExists(atPath: wrapper.path) {
            switch await resolveExtractConflict(
                conflictingItems: [wrapperName],
                destination: parentDirectory
            ) {
            case .replace:
                ledger.displacedItems.append(try await displaceLocalItem(wrapper))
            case .keepBoth:
                wrapper = uniqueCopyDestination(for: wrapper, in: parentDirectory)
            case .stop:
                throw FileOperationError.cancelled
            }
        }
        try fileManager.createDirectory(at: wrapper, withIntermediateDirectories: true)
        ledger.createdItems.append(wrapper)
        for item in items {
            try fileManager.moveItem(at: item, to: wrapper.appendingPathComponent(item.lastPathComponent))
        }
        return wrapper
    }

    nonisolated private static func sevenZipFailure(_ result: PtyProcessResult) -> FileOperationError {
        let diagnostic = result.outputString.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSevenZipPasswordMessage(diagnostic) {
            return .archivePasswordRequired
        }
        let message = diagnostic.isEmpty ? "Process exited with code \(result.status)" : diagnostic
        return .archiveExtractionFailed(message)
    }

    nonisolated static func isSevenZipPasswordMessage(_ message: String) -> Bool {
        ArchiveToolDiagnostics.isSevenZipPasswordMessage(message)
    }

    private var sevenZipPasswordEchoPolicy: PtyPasswordEchoPolicy {
        URL(fileURLWithPath: CompressionTool.sevenZip.path).lastPathComponent == "7zz"
            ? .disableBeforeResponse
            : .requireToolDisabled
    }

    nonisolated private static func parseSevenZipTopLevelEntries(_ output: String) -> Set<String> {
        var entries = Set<String>()
        var seenSeparator = false
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("----------") {
                seenSeparator = true
                continue
            }
            guard seenSeparator, trimmed.hasPrefix("Path = ") else { continue }
            let path = String(trimmed.dropFirst("Path = ".count))
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            if let first = components.first, first != "." {
                entries.insert(String(first))
            }
        }
        return entries
    }

    // MARK: - Non-ZIP Extraction (tar, 7z)

    private func performExtractNonZip(
        archive: URL,
        format: ArchiveFormat,
        ledger: ExtractionReplacementLedger
    ) async throws -> URL {
        let operation = FileOperation.extract(archive: archive, format: format)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        // Verify extraction tools are available
        if !CompressionTools.canExtract(format) {
            if let tool = CompressionTools.unavailableToolName(for: format) {
                throw FileOperationError.archiveToolNotFound(tool)
            }
        }

        let parentDir = archive.deletingLastPathComponent()
        let fileManager = FileManager.default

        enterProtectedPaths([archive, parentDir])
        defer { leaveProtectedPaths([archive, parentDir]) }

        let topLevelEntries = await listArchiveTopLevelEntries(archive: archive, format: format)
        let archiveName = archive.lastPathComponent
        let needsWrapperFolder = topLevelEntries.count > 1

        var extractionDir: URL
        var extractToTemp = false
        var appCreatedExtractionDir = false

        if needsWrapperFolder {
            var wrapperName = archive.deletingPathExtension().lastPathComponent
            if wrapperName.hasSuffix(".tar") {
                wrapperName = String(wrapperName.dropLast(4))
            }
            let wrapperURL = parentDir.appendingPathComponent(wrapperName)

            if fileManager.fileExists(atPath: wrapperURL.path) {
                let choice = await resolveExtractConflict(
                    conflictingItems: [wrapperName],
                    destination: parentDir
                )
                switch choice {
                case .replace:
                    ledger.displacedItems.append(try await displaceLocalItem(wrapperURL))
                    try fileManager.createDirectory(at: wrapperURL, withIntermediateDirectories: true)
                    extractionDir = wrapperURL
                    appCreatedExtractionDir = true
                    ledger.createdItems.append(wrapperURL)
                case .keepBoth:
                    let uniqueURL = uniqueCopyDestination(for: wrapperURL, in: parentDir)
                    try fileManager.createDirectory(at: uniqueURL, withIntermediateDirectories: true)
                    extractionDir = uniqueURL
                    appCreatedExtractionDir = true
                    ledger.createdItems.append(uniqueURL)
                case .stop:
                    throw FileOperationError.cancelled
                }
            } else {
                try fileManager.createDirectory(at: wrapperURL, withIntermediateDirectories: true)
                extractionDir = wrapperURL
                appCreatedExtractionDir = true
                ledger.createdItems.append(wrapperURL)
            }
        } else {
            let conflictingItems = topLevelEntries.filter { entry in
                entry != archiveName
                    && fileManager.fileExists(atPath: parentDir.appendingPathComponent(entry).path)
            }

            if !conflictingItems.isEmpty {
                let choice = await resolveExtractConflict(
                    conflictingItems: conflictingItems.sorted(),
                    destination: parentDir
                )
                switch choice {
                case .replace:
                    for item in conflictingItems {
                        let itemURL = parentDir.appendingPathComponent(item)
                        ledger.displacedItems.append(try await displaceLocalItem(itemURL))
                    }
                case .keepBoth:
                    extractToTemp = true
                case .stop:
                    throw FileOperationError.cancelled
                }
            }

            if extractToTemp {
                extractionDir = parentDir.appendingPathComponent(
                    ".detours-extract-\(UUID().uuidString)"
                )
                try fileManager.createDirectory(
                    at: extractionDir, withIntermediateDirectories: true
                )
                appCreatedExtractionDir = true
            } else {
                extractionDir = parentDir
            }
        }

        try checkCancelled()

        let contentsBefore = Set(
            (try? fileManager.contentsOfDirectory(atPath: extractionDir.path)) ?? []
        )

        do {
            switch format {
            case .rar:
                throw FileProviderError.unsupportedOperation("RAR extraction requires the bundled archive reader.")
            case .sevenZ:
                try await extractSevenZip(archive: archive, destination: extractionDir)
            case .tarGz, .tarBz2, .tarXz:
                try await extractTar(archive: archive, destination: extractionDir)
            case .zip:
                break // Unreachable — zip is handled by performExtractZip
            }
        } catch {
            if appCreatedExtractionDir {
                try? fileManager.removeItem(at: extractionDir)
            }
            throw error
        }

        let contentsAfter = Set(
            (try? fileManager.contentsOfDirectory(atPath: extractionDir.path)) ?? []
        )
        let newItems = contentsAfter.subtracting(contentsBefore)

        let resultURL: URL
        if needsWrapperFolder {
            resultURL = extractionDir
        } else if extractToTemp {
            var movedItems: [URL] = []
            do {
                for item in newItems {
                    let sourceItem = extractionDir.appendingPathComponent(item)
                    let destItem = parentDir.appendingPathComponent(item)
                    let finalDest: URL
                    if fileManager.fileExists(atPath: destItem.path) {
                        finalDest = uniqueCopyDestination(for: destItem, in: parentDir)
                    } else {
                        finalDest = destItem
                    }
                    try fileManager.moveItem(at: sourceItem, to: finalDest)
                    movedItems.append(finalDest)
                    ledger.createdItems.append(finalDest)
                }
            } catch {
                Self.removeAppCreatedDirectory(extractionDir)
                throw error
            }
            Self.removeAppCreatedDirectory(extractionDir)
            if movedItems.count == 1 {
                resultURL = movedItems[0]
            } else {
                resultURL = parentDir
            }
        } else {
            for item in newItems {
                ledger.createdItems.append(parentDir.appendingPathComponent(item))
            }
            for item in ledger.displacedItems
            where item.original.deletingLastPathComponent().standardizedFileURL == parentDir.standardizedFileURL {
                ledger.createdItems.append(item.original)
            }
            if newItems.count == 1, let newItem = newItems.first {
                resultURL = parentDir.appendingPathComponent(newItem)
            } else {
                resultURL = parentDir
            }
        }

        updateProgress(operation: operation, currentItem: resultURL, completed: 1, total: 1)
        return resultURL
    }

    private func listArchiveTopLevelEntries(
        archive: URL,
        format: ArchiveFormat
    ) async -> Set<String> {
        let process = Process()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        switch format {
        case .rar:
            return []
        case .zip:
            // ZIP listing is no longer used — performExtractZip discovers filenames
            // from the filesystem after extraction. Return empty to trigger wrapper folder.
            return []
        case .sevenZ:
            process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)
            process.arguments = ["l", "-slt", archive.path]
        case .tarGz, .tarBz2, .tarXz:
            process.executableURL = URL(fileURLWithPath: CompressionTool.tar.path)
            process.arguments = ["-tf", archive.path]
        }

        do {
            try process.run()
        } catch {
            return []
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return []
        }

        // Try UTF-8 first, fall back to Latin-1 for legacy-encoded filenames
        guard let output = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        var topLevel = Set<String>()

        if format == .sevenZ {
            var seenSeparator = false
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("----------") {
                    seenSeparator = true
                    continue
                }
                if seenSeparator, trimmed.hasPrefix("Path = ") {
                    let path = String(trimmed.dropFirst("Path = ".count))
                    var components = path.components(separatedBy: "/")
                    if components.first == "." { components.removeFirst() }
                    if let first = components.first, !first.isEmpty {
                        topLevel.insert(first)
                    }
                }
            }
        } else {
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                var components = trimmed.components(separatedBy: "/")
                if components.first == "." { components.removeFirst() }
                if let first = components.first, !first.isEmpty {
                    topLevel.insert(first)
                }
            }
        }

        return topLevel
    }

    enum ExtractConflictChoice {
        case replace
        case keepBoth
        case stop
    }

    func resolveExtractConflict(
        conflictingItems: [String],
        destination: URL
    ) async -> ExtractConflictChoice {
        #if DEBUG
        if let forced = conflictChoiceOverrideForTesting {
            switch forced {
            case .replace: return .replace
            case .keepBoth: return .keepBoth
            case .skip: return .stop
            }
        }
        #endif
        if isRunningTests {
            return .keepBoth
        }

        let alert = NSAlert()
        alert.messageText = "Item Already Exists"

        if conflictingItems.count == 1 {
            alert.informativeText = "\"\(conflictingItems[0])\" already exists in " +
                "\"\(destination.lastPathComponent)\". Do you want to replace it " +
                "with the extracted version?"
        } else {
            let names = conflictingItems.prefix(3)
                .map { "\"\($0)\"" }.joined(separator: ", ")
            let remaining = conflictingItems.count - 3
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            alert.informativeText = "\(names)\(suffix) already exist in " +
                "\"\(destination.lastPathComponent)\". Do you want to replace them " +
                "with the extracted versions?"
        }

        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Stop")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .replace
        default:
            return .stop
        }
    }

    private func extractSevenZip(archive: URL, destination: URL) async throws {
        try await validateSevenZipMemberPaths(archive: archive)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)
        process.arguments = ["x", "-y", "-bsp2", "-o\(destination.path)", archive.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: true, progressMode: .parseStderr(referenceSize: archiveSize))
    }

    private func extractTar(archive: URL, destination: URL) async throws {
        try await validateTarMemberPaths(archive: archive)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.tar.path)
        process.arguments = ["-xf", archive.path, "-C", destination.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        // Estimate uncompressed size as ~3x archive size for progress
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let mode: ArchiveProgressMode = archiveSize > 0 ? .pollFileSize(sourceSize: archiveSize * 3) : .none
        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: false, progressMode: mode)
    }

    private func validateTarMemberPaths(archive: URL) async throws {
        let listing = try await archiveMemberListing(
            executable: CompressionTool.tar.path,
            arguments: ["-tf", archive.path]
        )
        try Self.validateMemberPaths(listing.components(separatedBy: .newlines))
    }

    /// Lists zip members without extracting (the central directory is readable even for
    /// encrypted or 7z-only zips) and rejects entries that would escape the destination.
    private func validateZipMemberPaths(archive: URL) async throws {
        let listing = try await archiveMemberListing(
            executable: CompressionTool.unzip.path,
            arguments: ["-Z1", archive.path]
        )
        try Self.validateMemberPaths(listing.components(separatedBy: .newlines))
    }

    /// Lists 7z members without extracting. The bare -p supplies an empty password so a
    /// header-encrypted archive fails immediately instead of prompting on stdin; that
    /// failure surfaces as the password prompt, and the retry with the real password goes
    /// through the encrypted path, which validates from its own listing.
    private func validateSevenZipMemberPaths(archive: URL) async throws {
        let listing: String
        do {
            listing = try await archiveMemberListing(
                executable: CompressionTool.sevenZip.path,
                arguments: ["l", "-ba", "-slt", "-y", "-p", archive.path]
            )
        } catch FileOperationError.archiveExtractionFailed(let message) {
            if Self.isSevenZipPasswordMessage(message) {
                throw FileOperationError.archivePasswordRequired
            }
            throw FileOperationError.archiveExtractionFailed(message)
        }
        try Self.validateMemberPaths(Self.sevenZipListingMemberPaths(listing, requireSeparator: false))
    }

    private func archiveMemberListing(executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let outputTask = Task.detached {
            outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached {
            errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        let output = await outputTask.value
        let error = await errorTask.value

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: error, encoding: .utf8) ?? String(data: error, encoding: .isoLatin1)
            let stdoutText = String(data: output, encoding: .utf8) ?? String(data: output, encoding: .isoLatin1)
            let combined = [stderrText, stdoutText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw FileOperationError.archiveExtractionFailed(
                combined.isEmpty ? "Could not inspect archive contents" : combined
            )
        }
        guard let listing = String(data: output, encoding: .utf8)
                ?? String(data: output, encoding: .isoLatin1) else {
            throw FileOperationError.archiveExtractionFailed("Could not decode archive member paths")
        }
        return listing
    }

    nonisolated static func sevenZipListingMemberPaths(_ output: String, requireSeparator: Bool) -> [String] {
        ArchiveToolDiagnostics.sevenZipListingMemberPaths(output, requireSeparator: requireSeparator)
    }

    nonisolated static func validateMemberPaths(_ members: [String]) throws {
        if let unsafe = ArchiveToolDiagnostics.firstUnsafeMemberPath(members) {
            throw FileOperationError.archiveExtractionFailed("Archive contains an unsafe path: \(unsafe)")
        }
    }

    private func runExtractProcess(
        _ process: Process,
        errorPipe: Pipe,
        destination: URL,
        passwordProtected: Bool,
        progressMode: ArchiveProgressMode = .none
    ) async throws {
        // For 7z stderr progress parsing, use a separate pipe
        var stderrProgressPipe: Pipe?
        if case .parseStderr = progressMode {
            let pipe = Pipe()
            stderrProgressPipe = pipe
            process.standardError = pipe
        }

        try process.run()
        currentProcess = process
        defer { currentProcess = nil }

        // Start progress monitoring. In parseStderr mode it also accumulates
        // everything it drains: the pipe can only be read once, so this buffer is
        // the sole source for the tool's diagnostic text (and the password-error
        // wording isPasswordError matches) when the process fails.
        let progressTask = Task { [weak self] () -> Data? in
            switch progressMode {
            case .none:
                return nil
            case let .pollFileSize(expectedSize):
                while !Task.isCancelled {
                    guard (try? await Task.sleep(nanoseconds: 500_000_000)) != nil else { break } // 500ms
                    let currentSize = Self.directorySize(at: destination)
                    await MainActor.run { [weak self] in
                        guard let self, let operation = self.currentOperation else { return }
                        self.updateProgress(
                            operation: operation,
                            currentItem: destination,
                            completed: 0,
                            total: 0,
                            bytesCompleted: currentSize,
                            bytesTotal: expectedSize
                        )
                    }
                }
                return nil
            case let .parseStderr(refSize):
                guard let pipe = stderrProgressPipe else { return nil }
                let handle = pipe.fileHandleForReading
                var collected = Data()
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    collected.append(data)
                    if let str = String(data: data, encoding: .utf8) {
                        let pattern = #"(\d+)%"#
                        if let regex = try? NSRegularExpression(pattern: pattern),
                           let match = regex.matches(in: str, range: NSRange(str.startIndex..., in: str)).last,
                           let range = Range(match.range(at: 1), in: str),
                           let percent = Int(str[range]) {
                            let fraction = min(Double(percent) / 100.0, 1.0)
                            let bytesCompleted = Int64(Double(refSize) * fraction)
                            await MainActor.run { [weak self] in
                                guard let self, let operation = self.currentOperation else { return }
                                self.updateProgress(
                                    operation: operation,
                                    currentItem: destination,
                                    completed: 0,
                                    total: 0,
                                    bytesCompleted: bytesCompleted,
                                    bytesTotal: refSize
                                )
                            }
                        }
                    }
                }
                return collected
            }
        }

        // Await process with cancellation support (same pattern as runProcess)
        let once = OnceFlag()

        let terminationStatus: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { proc in
                    if once.tryFire() {
                        continuation.resume(returning: proc.terminationStatus)
                    }
                }

                if !process.isRunning {
                    if once.tryFire() {
                        continuation.resume(returning: process.terminationStatus)
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }

        progressTask.cancel()
        let parsedStderrData = await progressTask.value

        if isCancelled {
            // SAFETY: Never delete destination here — it may be a user directory (e.g. ~/Downloads).
            // Callers (performExtractZip, performExtractNonZip) handle cleanup of any temp/wrapper
            // directories they created via their own defer blocks and error handlers.
            throw FileOperationError.cancelled
        }

        if terminationStatus != 0 {
            // The progress task already drained the 7z progress pipe; its accumulated
            // buffer carries the diagnostic text. Append any tail left unread if that
            // task exited on cancellation before EOF.
            let errorData: Data
            if let stderrPipe = stderrProgressPipe {
                errorData = (parsedStderrData ?? Data()) + stderrPipe.fileHandleForReading.readDataToEndOfFile()
            } else {
                errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let decoded = (String(data: errorData, encoding: .utf8) ?? String(data: errorData, encoding: .isoLatin1))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorMessage = (decoded?.isEmpty == false) ? decoded! : "Process exited with code \(terminationStatus)"

            // Detect password-required errors
            if passwordProtected && isPasswordError(errorMessage, terminationStatus: terminationStatus) {
                throw FileOperationError.archivePasswordRequired
            }

            throw FileOperationError.archiveExtractionFailed(errorMessage)
        }
    }

    /// Calculate total size of a directory by summing all files recursively.
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let isRemovable = DirectoryLoader.isRemovableVolume(url)
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            var url = fileURL
            if isRemovable { url.removeAllCachedResourceValues() }
            if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private func isPasswordError(_ message: String, terminationStatus: Int32) -> Bool {
        ArchiveToolDiagnostics.isZipPasswordFailure(message: message, status: terminationStatus)
    }
}
