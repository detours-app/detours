import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension OperationDirectory {
    public func requirePrivate() throws {
        try requireCurrentPath()
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw Self.systemError() }
        guard information.st_uid == getuid(), information.st_mode & 0o777 == 0o700 else {
            throw OperationFilesystemError.unsupported
        }
    }

    public func createExclusiveFile(_ name: Data) throws -> (handle: FileHandle, identity: OperationObjectIdentity) {
        try requireCurrentPath()
        try Self.validateName(name)
        let opened = try Self.withBytes(name) {
            openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard opened >= 0 else { throw Self.systemError() }
        let handle = FileHandle(fileDescriptor: opened, closeOnDealloc: true)
        var information = stat()
        guard fstat(opened, &information) == 0 else { throw Self.systemError() }
        try requireCurrentPath()
        guard try observe(name).identity == Self.identity(information) else { throw OperationFilesystemError.identityChanged }
        return (handle, Self.identity(information))
    }

    public func removeOwnedFile(_ name: Data, identity: OperationObjectIdentity) throws {
        try requireCurrentPath()
        let current = try observe(name)
        guard current.kind == .file, current.identity == identity else { throw OperationFilesystemError.identityChanged }
        guard try Self.withBytes(name, { unlinkat(descriptor, $0, 0) }) == 0 else { throw Self.systemError() }
        try synchronize()
    }
}
