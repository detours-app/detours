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

    static let defaultResultCap = 1_000
    static let defaultTimeBudget: TimeInterval = 20
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

    /// Run the search, delivering matches in batches via `onBatch` as soon as they are found, so the
    /// client can render results progressively instead of waiting for the whole walk to finish.
    func find(query: Data, onBatch: ([Match]) -> Void) {
        find(query: Self.lossyString(query), onBatch: onBatch)
    }

    func find(query: String, onBatch: ([Match]) -> Void) {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return }

        let deadline = Date().addingTimeInterval(timeBudget)
        var total = 0
        var batch: [Match] = []
        var covered = Set<String>()

        let emit: (Match) -> Void = { match in
            batch.append(match)
            total += 1
            if batch.count >= self.batchSize {
                onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        let shouldStop: () -> Bool = { total >= self.resultCap || Date() >= deadline }

        for root in priorityRoots {
            let standardized = Self.standardized(root)
            guard !covered.contains(standardized) else { continue }
            walk(root: root, needle: needle, skipping: [], emit: emit, shouldStop: shouldStop)
            covered.insert(standardized)
            if shouldStop() { break }
        }

        if !shouldStop() {
            walk(root: rootFilesystem, needle: needle, skipping: covered, emit: emit, shouldStop: shouldStop)
        }

        if !batch.isEmpty {
            onBatch(batch)
        }
    }

    /// Collecting convenience used by tests: returns every match grouped into batches.
    func find(query: String) -> [[Match]] {
        var batches: [[Match]] = []
        find(query: query) { batches.append($0) }
        return batches
    }

    private func walk(
        root: String,
        needle: String,
        skipping: Set<String>,
        emit: (Match) -> Void,
        shouldStop: () -> Bool
    ) {
        guard let rootDevice = Self.deviceID(ofPath: root) else { return }
        let prunedAbsolutePaths = Self.pseudoPaths(under: rootFilesystem)

        var stack = [Self.standardized(root)]
        while let directory = stack.popLast() {
            if shouldStop() { return }

            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: directory)
            } catch {
                // Unreadable directory (permission denied, vanished): skip it, never abort the walk.
                continue
            }

            for name in names {
                if shouldStop() { return }
                let childPath = Self.join(directory, name)

                guard let info = Self.lstatInfo(ofPath: childPath) else { continue }

                if info.isDirectory, !info.isSymbolicLink {
                    let standardizedChild = Self.standardized(childPath)
                    let isPruned = Self.isNoiseDirectoryName(name)
                        || prunedAbsolutePaths.contains(standardizedChild)
                        || skipping.contains(standardizedChild)
                        || info.deviceID != rootDevice
                    if name.lowercased().contains(needle) {
                        emit(Match(path: ServerRemotePath(childPath), isDirectory: true))
                        if shouldStop() { return }
                    }
                    if !isPruned {
                        stack.append(standardizedChild)
                    }
                } else if name.lowercased().contains(needle) {
                    emit(Match(path: ServerRemotePath(childPath), isDirectory: false))
                }
            }
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
