import Foundation

/// Actor for thread-safe git status operations with caching
actor GitStatusProvider {
    static let shared = GitStatusProvider()

    private var cache: [URL: CachedStatus] = [:]
    private let cacheTTL: TimeInterval = 5.0

    private struct CachedStatus {
        let statuses: [URL: GitStatus]
        let timestamp: Date
    }

    /// Get git statuses for all files in a directory
    /// Returns empty dictionary if not a git repo or git is not available
    func status(for directory: URL) async -> [URL: GitStatus] {
        // Check cache first
        if let cached = cache[directory],
           Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.statuses
        }

        // Check if this is a git repo
        guard await isGitRepository(directory) else {
            cache[directory] = CachedStatus(statuses: [:], timestamp: Date())
            return [:]
        }

        // Run git status
        let statuses = await runGitStatus(in: directory)
        cache[directory] = CachedStatus(statuses: statuses, timestamp: Date())
        return statuses
    }

    /// Invalidate cache for a directory (call after file operations)
    func invalidateCache(for directory: URL) {
        cache.removeValue(forKey: directory)
    }

    /// Invalidate all cached statuses
    func invalidateAllCaches() {
        cache.removeAll()
    }

    // MARK: - Private

    private func isGitRepository(_ directory: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["rev-parse", "--is-inside-work-tree"]
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    private func runGitStatus(in directory: URL) async -> [URL: GitStatus] {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["status", "--porcelain", "-uall"]
            process.currentDirectoryURL = directory

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: [:])
                    return
                }

                let statuses = parseGitStatus(output, directory: directory)
                continuation.resume(returning: statuses)
            } catch {
                continuation.resume(returning: [:])
            }
        }
    }

    /// Parse git status --porcelain output
    /// Format: XY filename
    /// X = index status, Y = working tree status
    private func parseGitStatus(_ output: String, directory: URL) -> [URL: GitStatus] {
        var statuses: [URL: GitStatus] = [:]

        // Get git root to resolve paths correctly
        let gitRoot = getGitRoot(for: directory) ?? directory

        for line in output.components(separatedBy: "\n") {
            guard line.count >= 3 else { continue }

            let indexChar = line[line.startIndex]
            let workTreeChar = line[line.index(after: line.startIndex)]
            let filename = String(line.dropFirst(3))

            // Handle renamed files (format: "R  old -> new")
            var actualFilename: String
            if let arrowRange = filename.range(of: " -> ") {
                actualFilename = String(filename[arrowRange.upperBound...])
            } else {
                actualFilename = filename
            }

            // Strip quotes from filenames with special characters
            if actualFilename.hasPrefix("\"") && actualFilename.hasSuffix("\"") {
                actualFilename = String(actualFilename.dropFirst().dropLast())
            }

            let fileURL = gitRoot.appendingPathComponent(actualFilename)
            let status = determineStatus(index: indexChar, workTree: workTreeChar)

            if status != .clean {
                statuses[fileURL] = status
            }
        }

        return statuses
    }

    private func getGitRoot(for directory: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: output)
        } catch {
            return nil
        }
    }

    /// Determine git status from porcelain format codes
    private func determineStatus(index: Character, workTree: Character) -> GitStatus {
        // Untracked files
        if index == "?" && workTree == "?" {
            return .untracked
        }

        // Conflicts (unmerged)
        if index == "U" || workTree == "U" ||
           (index == "A" && workTree == "A") ||
           (index == "D" && workTree == "D") {
            return .conflict
        }

        // Staged (index has changes, working tree clean or also modified)
        if index != " " && index != "?" {
            // If only staged (working tree clean), show as staged
            if workTree == " " {
                return .staged
            }
            // If both staged and modified, show as modified (more urgent)
            return .modified
        }

        // Modified in working tree
        if workTree == "M" || workTree == "D" {
            return .modified
        }

        return .clean
    }
}
