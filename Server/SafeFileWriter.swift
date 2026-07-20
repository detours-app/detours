import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SafeFileWriter {
    static func write(_ data: Data, to url: URL, permissions: Int16? = nil) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions ?? 0o666))
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            if let permissions, fchmod(descriptor, mode_t(permissions)) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            close(descriptor)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
