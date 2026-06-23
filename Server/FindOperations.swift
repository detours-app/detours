import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Whole-host name search run inside the helper daemon.
///
/// Traverses the priority roots (the server's `$HOME`, then `/opt`) first, each staying on its
/// own filesystem, then the remainder of the root filesystem with the priority roots de-duplicated
/// out. Matches a case-insensitive substring against each entry's name, never its contents. Pseudo
/// filesystems (`/proc`, `/sys`, `/dev`) and common noise directories (`.git`, `node_modules`) are
/// pruned, symlinks are never followed, and permission-denied errors are swallowed. The walk stops at
/// the result cap or the time budget, whichever comes first, so a single find can never hold the
/// sequential RPC connection open indefinitely.
struct FindOperations {
    struct Match: Equatable {
        let path: ServerRemotePath
        let isDirectory: Bool
    }

    static let defaultResultCap = 500
    static let defaultTimeBudget: TimeInterval = 5
    static let defaultBatchSize = 50

    private let homeDirectory: String
    private let priorityRoots: [String]
    private let rootFilesystem: String
    private let resultCap: Int
    private let timeBudget: TimeInterval
    private let batchSize: Int
    private let fileManager: FileManager

    init(
        homeDirectory: String? = nil,
        priorityRoots: [String]? = nil,
        rootFilesystem: String = "/",
        resultCap: Int = defaultResultCap,
        timeBudget: TimeInterval = defaultTimeBudget,
        batchSize: Int = defaultBatchSize,
        fileManager: FileManager = .default
    ) {
        let home = homeDirectory
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        self.homeDirectory = home
        self.priorityRoots = priorityRoots ?? [home, "/opt"]
        self.rootFilesystem = rootFilesystem
        self.resultCap = max(1, resultCap)
        self.timeBudget = timeBudget
        self.batchSize = max(1, batchSize)
        self.fileManager = fileManager
    }

    /// Run the search and return the matches grouped into batches (one wire chunk each).
    /// Always returns at least one (possibly empty) batch so the caller can mark a final chunk.
    func find(query: Data) -> [[Match]] {
        find(query: Self.lossyString(query))
    }

    func find(query: String) -> [[Match]] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [[]] }

        let deadline = Date().addingTimeInterval(timeBudget)
        var matches: [Match] = []
        var covered = Set<String>()

        for root in priorityRoots {
            let standardized = Self.standardized(root)
            guard !covered.contains(standardized) else { continue }
            walk(root: root, needle: needle, deadline: deadline, skipping: [], into: &matches)
            covered.insert(standardized)
            if shouldStop(matches, deadline: deadline) { break }
        }

        if !shouldStop(matches, deadline: deadline) {
            walk(root: rootFilesystem, needle: needle, deadline: deadline, skipping: covered, into: &matches)
        }

        return batched(matches)
    }

    private func walk(
        root: String,
        needle: String,
        deadline: Date,
        skipping: Set<String>,
        into matches: inout [Match]
    ) {
        guard let rootDevice = Self.deviceID(ofPath: root) else { return }
        let prunedAbsolutePaths = Self.pseudoPaths(under: rootFilesystem)

        var stack = [Self.standardized(root)]
        while let directory = stack.popLast() {
            if shouldStop(matches, deadline: deadline) { return }

            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: directory)
            } catch {
                // Unreadable directory (permission denied, vanished): skip it, never abort the walk.
                continue
            }

            for name in names {
                if shouldStop(matches, deadline: deadline) { return }
                let childPath = Self.join(directory, name)

                guard let info = Self.lstatInfo(ofPath: childPath) else { continue }

                if info.isDirectory, !info.isSymbolicLink {
                    let standardizedChild = Self.standardized(childPath)
                    let isPruned = Self.isNoiseDirectoryName(name)
                        || prunedAbsolutePaths.contains(standardizedChild)
                        || skipping.contains(standardizedChild)
                        || info.deviceID != rootDevice
                    if name.lowercased().contains(needle) {
                        matches.append(Match(path: ServerRemotePath(childPath), isDirectory: true))
                        if shouldStop(matches, deadline: deadline) { return }
                    }
                    if !isPruned {
                        stack.append(standardizedChild)
                    }
                } else if name.lowercased().contains(needle) {
                    matches.append(Match(path: ServerRemotePath(childPath), isDirectory: false))
                }
            }
        }
    }

    private func shouldStop(_ matches: [Match], deadline: Date) -> Bool {
        matches.count >= resultCap || Date() >= deadline
    }

    private func batched(_ matches: [Match]) -> [[Match]] {
        guard !matches.isEmpty else { return [[]] }
        return stride(from: 0, to: matches.count, by: batchSize).map { start in
            Array(matches[start..<min(start + batchSize, matches.count)])
        }
    }

    // MARK: - Wire encoding (mirrors the client's RemoteFindCodec byte-for-byte)

    static func encode(_ matches: [Match]) -> Data {
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt32(UInt32(matches.count))
        for match in matches {
            writer.writeData(match.path.bytes)
            writer.writeBool(match.isDirectory)
        }
        return writer.data
    }

    // MARK: - Filesystem helpers

    private static func isNoiseDirectoryName(_ name: String) -> Bool {
        name == ".git" || name == "node_modules"
    }

    private static func pseudoPaths(under root: String) -> Set<String> {
        let base = standardized(root)
        return Set(["proc", "sys", "dev"].map { join(base, $0) })
    }

    private struct EntryInfo {
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let deviceID: dev_t
    }

    private static func lstatInfo(ofPath path: String) -> EntryInfo? {
        var buffer = stat()
        guard lstat(path, &buffer) == 0 else { return nil }
        let mode = buffer.st_mode & S_IFMT
        return EntryInfo(
            isDirectory: mode == S_IFDIR,
            isSymbolicLink: mode == S_IFLNK,
            deviceID: buffer.st_dev
        )
    }

    private static func deviceID(ofPath path: String) -> dev_t? {
        var buffer = stat()
        guard stat(path, &buffer) == 0 else { return nil }
        return buffer.st_dev
    }

    private static func standardized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.isEmpty ? path : standardized
    }

    private static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" {
            return "/" + name
        }
        return directory + "/" + name
    }

    private static func lossyString(_ data: Data) -> String {
        // Queries are carried as UTF-8 bytes on the wire; decoding for matching is intentionally lossy.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }
}
