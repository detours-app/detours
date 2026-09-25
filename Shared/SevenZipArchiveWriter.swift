import ArchiveStreamBridge
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SevenZipArchiveError: Error, Equatable {
    case invalidEntry
    case allocationFailed
    case nativeFailure(Int32)
}

public enum SevenZipArchiveWriter {
    public struct Entry: Sendable {
        public let name: String
        public let input: FileHandle?
        public let size: UInt64
        public let directory: Bool
        public let mode: UInt32
        public let modified: Date
        public let linkTarget: Data?

        public init(name: String, input: FileHandle?, size: UInt64, directory: Bool,
                    mode: UInt32, modified: Date, linkTarget: Data? = nil) {
            self.name = name
            self.input = input
            self.size = size
            self.directory = directory
            self.mode = mode
            self.modified = modified
            self.linkTarget = linkTarget
        }
    }

    public static func create(entries: [Entry], output: FileHandle, password: String?,
                              progress: @escaping @Sendable (UInt64) throws -> Void) throws {
        guard entries.count <= Int(UInt32.max), password?.contains("\0") != true else { throw SevenZipArchiveError.invalidEntry }
        var names: [UnsafeMutablePointer<CChar>] = []
        var links: [UnsafeMutableRawPointer] = []
        defer {
            for name in names { free(name) }
            for link in links { link.deallocate() }
        }
        var native: [detours_archive_entry] = []
        var seen = Set<String>()
        for entry in entries {
            let components = entry.name.split(separator: "/", omittingEmptySubsequences: false)
            let ticks = (entry.modified.timeIntervalSince1970 + 11_644_473_600) * 10_000_000
            guard !entry.name.contains("\0"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  seen.insert(entry.name).inserted, ticks.isFinite, ticks >= 0, ticks < Double(UInt64.max),
                  entry.directory || entry.input != nil || entry.linkTarget != nil else { throw SevenZipArchiveError.invalidEntry }
            guard let name = strdup(entry.name) else { throw SevenZipArchiveError.allocationFailed }
            names.append(name)
            var target: UnsafeMutableRawPointer?
            if let data = entry.linkTarget {
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, data.count), alignment: 1)
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                links.append(buffer)
                target = buffer
            }
            native.append(detours_archive_entry(
                name: UnsafePointer(name), descriptor: entry.input?.fileDescriptor ?? -1,
                is_directory: entry.directory ? 1 : 0, mode: entry.mode,
                size: entry.linkTarget.map { UInt64($0.count) } ?? entry.size,
                modified_filetime: UInt64(ticks), link_bytes: target.map { UnsafeRawPointer($0) }
            ))
        }
        let reporter = Reporter(progress)
        let result = native.withUnsafeBufferPointer { items in
            func invoke(_ secret: UnsafePointer<CChar>?) -> Int32 {
                detours_sevenzip_create(output.fileDescriptor, items.baseAddress, UInt32(items.count), secret, { context, bytes in
                    guard let context else { return 1 }
                    return Unmanaged<Reporter>.fromOpaque(context).takeUnretainedValue().report(bytes)
                }, Unmanaged.passUnretained(reporter).toOpaque())
            }
            if let password { return password.withCString { invoke($0) } }
            return invoke(nil)
        }
        if let failure = reporter.failure { throw failure }
        guard result == 0 else { throw SevenZipArchiveError.nativeFailure(result) }
    }

    private final class Reporter: @unchecked Sendable {
        private let lock = NSLock()
        private let progress: @Sendable (UInt64) throws -> Void
        private var recordedFailure: Error?

        init(_ progress: @escaping @Sendable (UInt64) throws -> Void) { self.progress = progress }

        var failure: Error? {
            lock.lock()
            defer { lock.unlock() }
            return recordedFailure
        }

        func report(_ bytes: UInt64) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            if recordedFailure != nil { return 1 }
            do {
                try progress(bytes)
                return 0
            } catch {
                recordedFailure = error
                return 1
            }
        }
    }
}
