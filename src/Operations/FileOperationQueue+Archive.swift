import AppKit
import Foundation

extension FileOperationQueue {
    // MARK: - Heavy-lane Operations (continued)

    func performDuplicateStructure(source: URL, destination: URL, yearSubstitution: (String, String)?) async throws -> URL {
        let fileManager = FileManager.default

        enterProtectedPaths([source, destination])
        defer { leaveProtectedPaths([source, destination]) }

        // Check if destination already exists
        if fileManager.fileExists(atPath: destination.path) {
            throw FileOperationError.destinationExists(destination)
        }

        // Collect all directories from source (sync operation)
        let directoriesToCreate = collectDirectories(from: source, to: destination, yearSubstitution: yearSubstitution)

        // Create all directories
        for dirURL in directoriesToCreate {
            do {
                try await runFileIO { try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil) }
            } catch {
                throw mapError(error, url: dirURL)
            }
        }

        return destination
    }

    private func collectDirectories(from source: URL, to destination: URL, yearSubstitution: (String, String)?) -> [URL] {
        var directoriesToCreate: [URL] = [destination]
        collectDirectoriesRecursive(source: source, destination: destination, relativePath: "", yearSubstitution: yearSubstitution, into: &directoriesToCreate)
        return directoriesToCreate
    }

    private func collectDirectoriesRecursive(source: URL, destination: URL, relativePath: String, yearSubstitution: (String, String)?, into directories: inout [URL]) {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for item in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            // Skip packages (bundles like .app, .framework)
            if let isPackage = try? item.resourceValues(forKeys: [.isPackageKey]).isPackage, isPackage {
                continue
            }

            // Build relative path for this directory
            var folderName = item.lastPathComponent
            if let (fromYear, toYear) = yearSubstitution {
                folderName = folderName.replacingOccurrences(of: fromYear, with: toYear)
            }

            let newRelativePath = relativePath.isEmpty ? folderName : "\(relativePath)/\(folderName)"
            let destURL = destination.appendingPathComponent(newRelativePath)
            directories.append(destURL)

            // Recurse into subdirectory
            collectDirectoriesRecursive(source: item, destination: destination, relativePath: newRelativePath, yearSubstitution: yearSubstitution, into: &directories)
        }
    }

    func performArchive(items: [URL], format: ArchiveFormat, archiveName: String, password: String?) async throws -> URL {
        if let password, !password.isEmpty {
            throw FileOperationError.archivePasswordUnsupported
        }
        let operation = FileOperation.archive(items: items, format: format)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        // Verify tools are available
        if let missingTool = CompressionTools.unavailableToolName(for: format) {
            throw FileOperationError.archiveToolNotFound(missingTool)
        }

        // Determine destination path
        let parentDir = items[0].deletingLastPathComponent()
        let archiveURL = uniqueArchiveDestination(in: parentDir, baseName: archiveName, format: format)

        let protectedScope = items + [archiveURL]
        enterProtectedPaths(protectedScope)
        defer { leaveProtectedPaths(protectedScope) }

        reserveDestination(archiveURL)
        defer { releaseDestination(archiveURL) }

        try checkCancelled()

        // Calculate total source size for progress reporting
        let sourceSize = Self.calculateTotalSize(of: items)

        // Build and run the compression process
        switch format {
        case .zip:
            try await runZip(items: items, destination: archiveURL, password: password, sourceSize: sourceSize)
        case .sevenZ:
            try await runSevenZip(items: items, destination: archiveURL, password: password, sourceSize: sourceSize)
        case .tarGz:
            try await runTar(items: items, destination: archiveURL, flag: "z", sourceSize: sourceSize)
        case .tarBz2:
            try await runTar(items: items, destination: archiveURL, flag: "j", sourceSize: sourceSize)
        case .tarXz:
            try await runTar(items: items, destination: archiveURL, flag: "J", sourceSize: sourceSize)
        }

        updateProgress(operation: operation, currentItem: archiveURL, completed: items.count, total: items.count)
        return archiveURL
    }

    /// Recursively calculate total file size of given items.
    nonisolated static func calculateTotalSize(of items: [URL]) -> Int64 {
        let fm = FileManager.default
        let isRemovable = items.first.map { DirectoryLoader.isRemovableVolume($0) } ?? false
        var total: Int64 = 0
        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) {
                    for case let fileURL as URL in enumerator {
                        var url = fileURL
                        if isRemovable { url.removeAllCachedResourceValues() }
                        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                           values.isRegularFile == true {
                            total += Int64(values.totalFileAllocatedSize ?? 0)
                        }
                    }
                }
            } else {
                var url = item
                if isRemovable { url.removeAllCachedResourceValues() }
                if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) {
                    total += Int64(values.totalFileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    private func runZip(items: [URL], destination: URL, password: String?, sourceSize: Int64) async throws {
        let parentDir = items[0].deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.zip.path)
        process.currentDirectoryURL = URL(fileURLWithPath: parentDir)

        var arguments = ["-r", "-q"]
        if let password, !password.isEmpty {
            throw FileOperationError.archivePasswordUnsupported
        }
        arguments.append(destination.path)
        for item in items {
            arguments.append(item.lastPathComponent)
        }
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        let mode: ArchiveProgressMode = sourceSize > 0 ? .pollFileSize(sourceSize: sourceSize) : .none
        try await runProcess(process, errorPipe: errorPipe, partialFile: destination, progressMode: mode)
    }

    private func runSevenZip(items: [URL], destination: URL, password: String?, sourceSize: Int64) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)

        var arguments = ["a", "-t7z", "-bsp2"]
        if let password, !password.isEmpty {
            throw FileOperationError.archivePasswordUnsupported
        }
        arguments.append(destination.path)
        for item in items {
            arguments.append(item.path)
        }
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await runProcess(process, errorPipe: errorPipe, partialFile: destination, progressMode: .parseStderr(referenceSize: sourceSize))
    }

    private func runTar(items: [URL], destination: URL, flag: String, sourceSize: Int64) async throws {
        let parentDir = items[0].deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.tar.path)
        process.currentDirectoryURL = URL(fileURLWithPath: parentDir)

        var arguments = ["-c\(flag)f", destination.path]
        for item in items {
            arguments.append(item.lastPathComponent)
        }
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        let mode: ArchiveProgressMode = sourceSize > 0 ? .pollFileSize(sourceSize: sourceSize) : .none
        try await runProcess(process, errorPipe: errorPipe, partialFile: destination, progressMode: mode)
    }

    /// Progress mode for archive subprocess monitoring.
    enum ArchiveProgressMode {
        /// No intermediate progress (used when source size is unknown)
        case none
        /// Poll the output file size against a known source size (ZIP, TAR)
        case pollFileSize(sourceSize: Int64)
        /// Parse percentage from 7z's stderr output (`-bsp2` flag).
        /// `referenceSize` is used to convert percentage into byte values for display.
        case parseStderr(referenceSize: Int64)
    }

    private func runProcess(
        _ process: Process,
        errorPipe: Pipe,
        partialFile: URL,
        progressMode: ArchiveProgressMode = .none
    ) async throws {
        // For 7z stderr progress parsing, we need a separate pipe
        var stderrProgressPipe: Pipe?
        if case .parseStderr = progressMode {
            let pipe = Pipe()
            stderrProgressPipe = pipe
            process.standardError = pipe
        }

        try process.run()
        currentProcess = process
        defer { currentProcess = nil }

        // Start progress monitoring task
        let progressTask = Task { [weak self] in
            switch progressMode {
            case .none:
                break
            case let .pollFileSize(sourceSize):
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    let attrs = try? FileManager.default.attributesOfItem(atPath: partialFile.path)
                    let currentSize = (attrs?[.size] as? Int64) ?? 0
                    await MainActor.run { [weak self] in
                        guard let self, let operation = self.currentOperation else { return }
                        self.updateProgress(
                            operation: operation,
                            currentItem: partialFile,
                            completed: 0,
                            total: 0,
                            bytesCompleted: currentSize,
                            bytesTotal: sourceSize
                        )
                    }
                }
            case let .parseStderr(refSize):
                guard let pipe = stderrProgressPipe else { break }
                let handle = pipe.fileHandleForReading
                // Read stderr chunks and parse percentage
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty { break } // EOF
                    if let str = String(data: data, encoding: .utf8) {
                        // 7z progress format: " 45%" with backspace characters
                        // Find the last percentage match
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
                                    currentItem: partialFile,
                                    completed: 0,
                                    total: 0,
                                    bytesCompleted: bytesCompleted,
                                    bytesTotal: refSize
                                )
                            }
                        }
                    }
                }
            }
        }

        // Await process with cancellation support
        // Uses withTaskCancellationHandler to avoid hung continuation if process dies
        let once = OnceFlag()

        let terminationStatus: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { proc in
                    if once.tryFire() {
                        continuation.resume(returning: proc.terminationStatus)
                    }
                }

                // Guard: process may have already exited before handler was set
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

        if isCancelled {
            try? FileManager.default.removeItem(at: partialFile)
            throw FileOperationError.cancelled
        }

        if terminationStatus != 0 {
            // For 7z with separate progress pipe, read error output from that pipe
            let errorData: Data
            if let stderrPipe = stderrProgressPipe {
                errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            } else {
                errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let decoded = (String(data: errorData, encoding: .utf8) ?? String(data: errorData, encoding: .isoLatin1))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorMessage = (decoded?.isEmpty == false) ? decoded! : "Process exited with code \(terminationStatus)"
            try? FileManager.default.removeItem(at: partialFile)
            throw FileOperationError.archiveProcessFailed(errorMessage)
        }
    }

    private func uniqueArchiveDestination(in directory: URL, baseName: String, format: ArchiveFormat) -> URL {
        let fileManager = FileManager.default
        let ext = format.fileExtension

        var attempt = 1
        while true {
            let name: String
            if attempt == 1 {
                name = "\(baseName).\(ext)"
            } else {
                name = "\(baseName) \(attempt).\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
                return candidate
            }
            attempt += 1
        }
    }
}
