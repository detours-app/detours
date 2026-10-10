import ArchiveStreamBridge
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SevenZipArchiveReader {
    public enum Format: Int32, Sendable {
        case sevenZ = 0, zip = 1, tar = 2, gzip = 3, bzip2 = 4, xz = 5, rar = 6, rar5 = 7
    }

    public struct Member: Equatable, Sendable {
        public let index: UInt32
        public let name: String
        public let symbolicLink: String?
        public let hardLink: String?
        public let size: UInt64?
        public let modified: Date?
        public let mode: UInt32
        public let directory: Bool
        public let encrypted: Bool
        public let splitBefore: Bool
        public let splitAfter: Bool
    }

    public struct RarVolume: Sendable {
        public let isVolume: Bool
        public let index: UInt32?
        public let members: [Member]
    }

    public static func inspectRarVolume(input: FileHandle, format: Format, password: String?,
                                        progress: @escaping @Sendable (UInt64) throws -> Void) throws -> RarVolume {
        guard [.rar, .rar5].contains(format), password?.contains("\0") != true else {
            throw SevenZipArchiveError.invalidEntry
        }
        let state = State(output: nil, volume: nil, rar: true, progress: progress)
        var info = detours_rar_volume_info()
        func invoke(_ secret: UnsafePointer<CChar>?) -> Int32 {
            detours_rar_inspect(format.rawValue, input.fileDescriptor, secret, &info, { context, index, member in
                guard let context, let member else { return 1 }
                return Unmanaged<State>.fromOpaque(context).takeUnretainedValue().visit(index, member.pointee)
            }, { context, bytes in
                guard let context else { return 1 }
                return Unmanaged<State>.fromOpaque(context).takeUnretainedValue().report(bytes)
            }, Unmanaged.passUnretained(state).toOpaque())
        }
        let result = password.map { secret in secret.withCString { invoke($0) } } ?? invoke(nil)
        if let failure = state.failure { throw failure }
        try checkResult(result)
        return RarVolume(isVolume: info.is_volume != 0, index: info.has_index == 0 ? nil : info.index, members: state.members)
    }

    /// Lists before extracting. Output returns a new empty handle which this call closes.
    /// Member names are metadata only; the caller must validate its complete filesystem plan.
    public static func read(input: FileHandle, format: Format, password: String?,
                            inputName: String? = nil,
                            openVolume: (@Sendable (String) throws -> FileHandle)? = nil,
                            output: (@Sendable (Member) throws -> FileHandle)? = nil,
                            progress: @escaping @Sendable (UInt64) throws -> Void) throws -> [Member] {
        guard password?.contains("\0") != true, inputName?.contains("\0") != true else { throw SevenZipArchiveError.invalidEntry }
        let state = State(output: output, volume: openVolume, rar: format == .rar || format == .rar5, progress: progress)
        func invoke(_ secret: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?) -> Int32 {
            let opener: detours_archive_input? = output == nil ? nil : { context, index in
                guard let context else { return -1 }
                return Unmanaged<State>.fromOpaque(context).takeUnretainedValue().open(index)
            }
            return detours_archive_read(format.rawValue, input.fileDescriptor, secret, name, { context, name in
                guard let context, let name, let decoded = String(validatingCString: name) else { return -1 }
                return Unmanaged<State>.fromOpaque(context).takeUnretainedValue().openVolume(decoded)
            }, { context, index, member in
                guard let context, let member else { return 1 }
                return Unmanaged<State>.fromOpaque(context).takeUnretainedValue().visit(index, member.pointee)
            }, opener, { context, bytes in
                guard let context else { return 1 }
                return Unmanaged<State>.fromOpaque(context).takeUnretainedValue().report(bytes)
            }, Unmanaged.passUnretained(state).toOpaque())
        }
        func withName(_ secret: UnsafePointer<CChar>?) -> Int32 {
            inputName.map { name in name.withCString { invoke(secret, $0) } } ?? invoke(secret, nil)
        }
        let result = password.map { secret in secret.withCString { withName($0) } } ?? withName(nil)
        if let failure = state.failure { throw failure }
        try checkResult(result)
        return state.members
    }

    private static func checkResult(_ result: Int32) throws {
        switch result {
        case 0: break
        case -1001: throw SevenZipArchiveError.passwordRequired
        case -1002: throw SevenZipArchiveError.wrongPassword
        case -1003: throw SevenZipArchiveError.passwordOrCorruption
        case -1004: throw SevenZipArchiveError.corruptArchive
        case -1005: throw SevenZipArchiveError.unsupportedMethod
        case -1006: throw SevenZipArchiveError.missingVolume(nil)
        case -1007: throw SevenZipArchiveError.volumeLimitExceeded
        default: throw SevenZipArchiveError.nativeFailure(result)
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let output: (@Sendable (Member) throws -> FileHandle)?
        private let volume: (@Sendable (String) throws -> FileHandle)?
        private let rar: Bool
        private var totalSize: UInt64 = 0
        private let progress: @Sendable (UInt64) throws -> Void
        private var recordedFailure: Error?
        private var listed: [Member] = []

        init(output: (@Sendable (Member) throws -> FileHandle)?, volume: (@Sendable (String) throws -> FileHandle)?,
             rar: Bool, progress: @escaping @Sendable (UInt64) throws -> Void) {
            self.output = output
            self.volume = volume
            self.rar = rar
            self.progress = progress
        }

        var failure: Error? {
            lock.lock()
            defer { lock.unlock() }
            return recordedFailure
        }

        var members: [Member] {
            lock.lock()
            defer { lock.unlock() }
            return listed
        }

        func visit(_ index: UInt32, _ native: detours_archive_member) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            guard recordedFailure == nil else { return 1 }
            guard index == listed.count, let name = native.name.flatMap({ String(validatingCString: $0) }) else {
                recordedFailure = SevenZipArchiveError.invalidEntry
                return 1
            }
            let symbolic = native.symbolic_link.flatMap { String(validatingCString: $0) }
            let hard = native.hard_link.flatMap { String(validatingCString: $0) }
            guard native.symbolic_link == nil || symbolic != nil, native.hard_link == nil || hard != nil else {
                recordedFailure = SevenZipArchiveError.invalidEntry
                return 1
            }
            if rar, native.is_directory == 0 {
                let (total, overflow) = totalSize.addingReportingOverflow(native.size)
                guard native.has_size != 0, native.size <= UInt64(Int64.max), !overflow else {
                    recordedFailure = SevenZipArchiveError.invalidEntry
                    return 1
                }
                totalSize = total
            }
            listed.append(Member(index: index, name: name, symbolicLink: symbolic, hardLink: hard,
                                 size: native.has_size == 0 ? nil : native.size,
                                 modified: native.has_modified == 0 ? nil : Date(
                                    timeIntervalSince1970: Double(native.modified_filetime) / 10_000_000 - 11_644_473_600
                                 ), mode: native.mode, directory: native.is_directory != 0, encrypted: native.is_encrypted != 0,
                                 splitBefore: native.split_before != 0, splitAfter: native.split_after != 0))
            return 0
        }

        func open(_ index: UInt32) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            guard recordedFailure == nil, listed.indices.contains(Int(index)), let output else { return -1 }
            do {
                let handle = try output(listed[Int(index)])
                defer { try? handle.close() }
                let descriptor = dup(handle.fileDescriptor)
                guard descriptor >= 0 else { throw SevenZipArchiveError.inputFailure(errno) }
                return descriptor
            } catch {
                recordedFailure = error
                return -1
            }
        }

        func openVolume(_ name: String) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            guard recordedFailure == nil else { return -1 }
            do {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                      !name.contains("\\"), !name.contains(":"), !name.contains("\0") else {
                    throw SevenZipArchiveError.invalidEntry
                }
                guard let volume else { throw SevenZipArchiveError.missingVolume(name) }
                let handle = try volume(name)
                defer { try? handle.close() }
                let descriptor = dup(handle.fileDescriptor)
                guard descriptor >= 0 else { throw SevenZipArchiveError.inputFailure(errno) }
                return descriptor
            } catch {
                recordedFailure = error
                return -1
            }
        }

        func report(_ bytes: UInt64) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            guard recordedFailure == nil else { return 1 }
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
