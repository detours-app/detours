import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SafeFileWriter {
    /// Creates a new file with a plain exclusive open and hands back its handle. Foundation's
    /// atomic file creation is not used: on the static Linux build it opens its temporary file
    /// with an empty path and fails every time.
    static func createHandle(at url: URL, permissions: Int16? = nil) throws -> FileHandle {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions ?? 0o666))
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let permissions, fchmod(descriptor, mode_t(permissions)) != 0 {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            try? FileManager.default.removeItem(at: url)
            throw failure
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func write(_ data: Data, to url: URL, permissions: Int16? = nil) throws {
        let handle = try createHandle(at: url, permissions: permissions)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
