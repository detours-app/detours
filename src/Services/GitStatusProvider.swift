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

    func status(for directory: Location) async -> [Location: GitStatus] {
        switch directory {
        case .local(let url):
            let statuses = await status(for: url)
            return Dictionary(uniqueKeysWithValues: statuses.map { (.local($0.key), $0.value) })
        case .remote:
            return [:]
        }
    }

    /// Invalidate cache for a directory (call after file operations)
    func invalidateCache(for directory: URL) {
        cache.removeValue(forKey: directory)
    }

    func invalidateCache(for directory: Location) {
        guard case .local(let url) = directory else { return }
        invalidateCache(for: url)
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
            process.arguments = ["-c", "core.fsmonitor=false", "rev-parse", "--is-inside-work-tree"]
            process.environment = ["GIT_CONFIG_NOSYSTEM": "1"]
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
            process.arguments = ["-c", "core.fsmonitor=false", "status", "--porcelain", "-uall"]
            process.environment = ["GIT_CONFIG_NOSYSTEM": "1"]
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

            // Filenames with special characters arrive C-quoted; decode them, don't just unwrap them.
            if actualFilename.hasPrefix("\""), actualFilename.hasSuffix("\""), actualFilename.count >= 2 {
                actualFilename = Self.unquoteCQuoted(String(actualFilename.dropFirst().dropLast()))
            }

            let fileURL = gitRoot.appendingPathComponent(actualFilename)
            let status = determineStatus(index: indexChar, workTree: workTreeChar)

            if status != .clean {
                statuses[fileURL] = status
            }
        }

        return statuses
    }

    /// Decodes git's C-style quoting (octal \nnn escapes plus \\, \", \t, \n, \r) back into the real bytes.
    /// git --porcelain quotes any filename with non-ASCII or special characters when core.quotepath is on
    /// (the default), so stripping the surrounding quotes alone leaves literal escape sequences in the path.
    ///
    /// The remote helper carries its own copy in Server/GitOperations.swift because it ships as a
    /// standalone binary. GitPorcelainUnquoteTests asserts the two stay in agreement.
    static func unquoteCQuoted(_ value: String) -> String {
        let scalars = Array(value.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < scalars.count {
            let byte = scalars[index]
            guard byte == UInt8(ascii: "\\") else {
                bytes.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else {
                bytes.append(byte)
                break
            }
            let escape = scalars[index]
            index += 1
            switch escape {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "\\"): bytes.append(0x5C)
            case UInt8(ascii: "\""): bytes.append(0x22)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var octal = Int(escape - UInt8(ascii: "0"))
                var consumed = 0
                while consumed < 2, index < scalars.count,
                      scalars[index] >= UInt8(ascii: "0"), scalars[index] <= UInt8(ascii: "7") {
                    octal = octal * 8 + Int(scalars[index] - UInt8(ascii: "0"))
                    index += 1
                    consumed += 1
                }
                bytes.append(UInt8(octal & 0xFF))
            default:
                bytes.append(escape)
            }
        }
        // Git encodes quoted filenames as UTF-8 byte sequences; decode them byte-exact.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    private func getGitRoot(for directory: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false", "rev-parse", "--show-toplevel"]
        process.environment = ["GIT_CONFIG_NOSYSTEM": "1"]
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
