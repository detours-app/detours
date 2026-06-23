import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Whole-host name search run inside the helper daemon.
///
/// Delegates the traversal to the system `find` tool, which is far faster and more complete than a
/// hand-rolled walk on a large host: it searches the priority roots (the server's `$HOME`, then
/// `/opt`) first, then the rest of the root filesystem with the priority roots pruned out. Matches a
/// case-insensitive substring of the entry name (never contents). Hidden entries (caches, dotdirs),
/// `node_modules`, the pseudo filesystems (`/proc`, `/sys`, `/dev`) and external mounts are pruned,
/// and symlinked directories are not followed. Results stream out via `onBatch` as `find` prints
/// them; the search stops at the result cap or the time budget, whichever comes first.
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
    }

    /// Run the search, delivering matches in batches via `onBatch` as soon as `find` reports them.
    func find(query: Data, onBatch: ([Match]) -> Void) {
        find(query: Self.lossyString(query), onBatch: onBatch)
    }

    func find(query: String, onBatch: ([Match]) -> Void) {
        guard !query.isEmpty else { return }
        let pattern = "*" + Self.globEscaped(query) + "*"
        let deadline = Date().addingTimeInterval(timeBudget)

        var total = 0
        var batch: [Match] = []
        let emit: (Match) -> Void = { match in
            batch.append(match)
            total += 1
            if batch.count >= self.batchSize {
                onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        let shouldStop: () -> Bool = { total >= self.resultCap || Date() >= deadline }
        func flushPending() {
            guard !batch.isEmpty else { return }
            onBatch(batch)
            batch.removeAll(keepingCapacity: true)
        }

        // Priority roots first (home, /opt), in order. Flush after this pass so home matches reach
        // the client immediately, before the whole-host pass runs.
        let existingPriority = priorityRoots.filter { FileManager.default.fileExists(atPath: $0) }
        if !existingPriority.isEmpty {
            let pass = FindPass(startPoints: existingPriority, prunePaths: [], pattern: pattern)
            runFind(pass, deadline: deadline, emit: emit, shouldStop: shouldStop)
            flushPending()
        }

        // Then the rest of the root filesystem, with the priority roots pruned so they are not re-walked.
        if !shouldStop() {
            let prune = priorityRoots + Self.pseudoPaths(under: rootFilesystem) + Self.externalMountGlobs
            let pass = FindPass(startPoints: [rootFilesystem], prunePaths: prune, pattern: pattern)
            runFind(pass, deadline: deadline, emit: emit, shouldStop: shouldStop)
        }

        flushPending()
    }

    private struct FindPass {
        let startPoints: [String]
        let prunePaths: [String]
        let pattern: String
    }

    /// Collecting convenience used by tests: returns every match grouped into batches.
    func find(query: String) -> [[Match]] {
        var batches: [[Match]] = []
        find(query: query) { batches.append($0) }
        return batches
    }

    private func runFind(
        _ pass: FindPass,
        deadline: Date,
        emit: (Match) -> Void,
        shouldStop: () -> Bool
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = pass.startPoints + Self.findExpression(prunePaths: pass.prunePaths, pattern: pass.pattern)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }

        // Watchdog: terminate find at the deadline even if it is blocked producing no output.
        let remaining = deadline.timeIntervalSinceNow
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        if remaining > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining, execute: watchdog)
        } else {
            process.terminate()
        }

        var buffer = Data()
        let handle = output.fileHandleForReading
        readLoop: while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let index = buffer.firstIndex(of: 0) {
                let pathBytes = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)
                guard !pathBytes.isEmpty else { continue }
                let isDirectory = Self.lstatInfo(ofPathBytes: pathBytes)?.isDirectory ?? false
                emit(Match(path: ServerRemotePath(bytes: pathBytes), isDirectory: isDirectory))
                if shouldStop() {
                    process.terminate()
                    break readLoop
                }
            }
        }

        watchdog.cancel()
        process.waitUntilExit()
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

    // MARK: - find expression

    /// Build the `find` expression: prune hidden/noise/pruned paths, then match the name pattern.
    private static func findExpression(prunePaths: [String], pattern: String) -> [String] {
        var pruneClause: [String] = ["(", "-name", ".*", "-o", "-name", "node_modules"]
        for path in prunePaths {
            pruneClause += ["-o", "-path", path]
        }
        pruneClause += [")", "-prune"]
        return pruneClause + ["-o", "-iname", pattern, "-print0"]
    }

    /// Absolute mount points to prune on the whole-host pass so the search never wanders into
    /// network shares, removable media, or pseudo filesystems. Expressed as globs covering the
    /// mount and its contents.
    private static let externalMountGlobs = [
        "/Volumes", "/Volumes/*", "/mnt", "/mnt/*", "/media", "/media/*", "/net", "/net/*",
    ]

    private static func pseudoPaths(under root: String) -> [String] {
        let base = (root as NSString).standardizingPath
        let normalized = base.isEmpty ? root : base
        return ["proc", "sys", "dev"].map { join(normalized, $0) }
    }

    private static func globEscaped(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if "*?[]\\".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    // MARK: - Filesystem helpers

    private struct EntryInfo {
        let isDirectory: Bool
    }

    private static func lstatInfo(ofPathBytes pathBytes: Data) -> EntryInfo? {
        var cString = [CChar](repeating: 0, count: pathBytes.count + 1)
        pathBytes.withUnsafeBytes { raw in
            for (index, byte) in raw.enumerated() {
                cString[index] = CChar(bitPattern: byte)
            }
        }
        var buffer = stat()
        guard lstat(cString, &buffer) == 0 else { return nil }
        return EntryInfo(isDirectory: (buffer.st_mode & S_IFMT) == S_IFDIR)
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
