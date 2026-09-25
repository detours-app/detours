import FilesystemPrimitives
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum OperationFilesystemError: Error, Equatable {
    case invalidPath
    case system(Int32)
    case unsupported
    case identityChanged
    case unexpectedContents
}

public final class OperationDirectory: @unchecked Sendable {
    let descriptor: Int32
    public let path: Data
    public let identity: OperationObjectIdentity

    public init(path: Data) throws {
        let descriptor = try Self.withBytes(path) { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw Self.systemError() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw Self.systemError() }
            self.identity = Self.identity(info)
            self.path = path
            self.descriptor = descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    deinit { _ = close(descriptor) }

    public func childPath(_ name: Data) throws -> Data {
        try Self.validateName(name)
        return path + (path.last == 47 ? Data() : Data([47])) + name
    }

    public func observe(_ name: Data) throws -> OperationObservation {
        try Self.validateName(name)
        var info = stat()
        let result = try Self.withBytes(name) { fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { throw Self.systemError() }
        let kind: OperationObservation.Kind
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = .file
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: throw OperationFilesystemError.unsupported
        }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        #else
        let modified = info.st_mtim
        let changed = info.st_ctim
        #endif
        let version = "\(info.st_size):\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec):\(info.st_mode)"
        let contentVersion = "\(info.st_size):\(modified.tv_sec):\(modified.tv_nsec):\(info.st_mode):\(info.st_uid):\(info.st_gid)"
        return OperationObservation(identity: Self.identity(info), kind: kind, version: Data(version.utf8),
                                    byteCount: UInt64(max(0, info.st_size)), sha256: nil,
                                    linkTarget: kind == .symbolicLink ? try readLink(name) : nil,
                                    contentVersion: Data(contentVersion.utf8))
    }

    public func lookup(_ name: Data) throws -> OperationLookup<OperationObservation> {
        do { return .found(try observe(name)) } catch OperationFilesystemError.system(let code) {
            switch code {
            case ENOENT: return .missing
            case EACCES, EPERM: return .denied
            default: throw OperationFilesystemError.system(code)
            }
        } catch OperationFilesystemError.unsupported { return .unsupported }
    }

    public func moveExclusive(_ name: Data, to destination: OperationDirectory, named target: Data,
                              expected: OperationObservation) throws -> OperationObservation {
        try Self.validateName(name)
        try Self.validateName(target)
        try requireCurrentPath()
        try destination.requireCurrentPath()
        let current = try observe(name)
        guard current.identity == expected.identity, current.version == expected.version,
              current.kind == expected.kind, current.linkTarget == expected.linkTarget else {
            throw OperationFilesystemError.identityChanged
        }
        let result = try Self.withBytes(name) { source in
            try Self.withBytes(target) { target in
                detours_rename_exclusive(descriptor, source, destination.descriptor, target)
            }
        }
        guard result == 0 else { throw Self.systemError() }
        try synchronize()
        try destination.synchronize()
        try destination.requireCurrentPath()
        let moved = try destination.observe(target)
        guard moved.identity == expected.identity, moved.kind == expected.kind, moved.linkTarget == expected.linkTarget,
              expected.contentVersion == nil || moved.contentVersion == expected.contentVersion else {
            throw OperationFilesystemError.identityChanged
        }
        return moved
    }

    public func createDirectory(_ name: Data) throws -> OperationObservation {
        try Self.validateName(name)
        try requireCurrentPath()
        let result = try Self.withBytes(name) { mkdirat(descriptor, $0, mode_t(0o777)) }
        guard result == 0 else { throw Self.systemError() }
        try synchronize()
        try requireCurrentPath()
        return try observe(name)
    }

    public func synchronize() throws {
        guard fsync(descriptor) == 0 else { throw Self.systemError() }
    }

    public func requireCurrentPath() throws {
        let current = try OperationDirectory(path: path)
        guard current.identity == identity else { throw OperationFilesystemError.identityChanged }
    }

    public func names() throws -> Set<Data> {
        let copied = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copied >= 0 else { throw Self.systemError() }
        guard let directory = fdopendir(copied) else {
            let error = Self.systemError()
            _ = close(copied)
            throw error
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names = Set<Data>()
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Self.systemError() }
                return names
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    Data(bytes: $0, count: strlen($0))
                }
            }
            if name != Data(".".utf8), name != Data("..".utf8) { names.insert(name) }
        }
    }

    private func readLink(_ name: Data) throws -> Data {
        var capacity = 256
        while capacity <= 1_048_576 {
            var bytes = [CChar](repeating: 0, count: capacity)
            let count = try Self.withBytes(name) { readlinkat(descriptor, $0, &bytes, capacity) }
            guard count >= 0 else { throw Self.systemError() }
            if count < capacity { return Data(bytes: bytes, count: count) }
            capacity *= 2
        }
        throw OperationFilesystemError.unsupported
    }

    static func identity(_ info: stat) -> OperationObjectIdentity {
        OperationObjectIdentity(volume: Data(String(info.st_dev).utf8), object: Data(String(info.st_ino).utf8))
    }

    static func validateName(_ name: Data) throws {
        guard !name.isEmpty, !name.contains(0), !name.contains(47), name != Data(".".utf8), name != Data("..".utf8) else {
            throw OperationFilesystemError.invalidPath
        }
    }

    static func withBytes<Result>(_ bytes: Data, _ body: (UnsafePointer<CChar>) throws -> Result) throws -> Result {
        guard !bytes.isEmpty, !bytes.contains(0) else { throw OperationFilesystemError.invalidPath }
        let terminated = bytes.map { CChar(bitPattern: $0) } + [0]
        return try terminated.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { throw OperationFilesystemError.invalidPath }
            return try body(pointer)
        }
    }

    static func systemError() -> OperationFilesystemError {
        switch errno {
        case ENOTSUP, ENOSYS, EINVAL: return .unsupported
        default: return .system(errno)
        }
    }
}
