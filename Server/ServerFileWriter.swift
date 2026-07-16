import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum ServerFileWriter {
    static func write(_ data: Data, to destination: URL, atomically: Bool) throws {
        if !atomically {
            try writeDirectly(data, to: destination)
            return
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).detours-write-\(UUID().uuidString)"
        )
        do {
            try writeDirectly(data, to: temporary)
            guard rename(temporary.path, destination.path) == 0 else {
                throw posixError("rename", path: destination.path)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func writeDirectly(_ data: Data, to destination: URL) throws {
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError("open", path: destination.path) }
        defer { close(descriptor) }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = systemWrite(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw posixError("write", path: destination.path)
                }
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError("fsync", path: destination.path) }
    }

    private static func systemWrite(
        _ descriptor: Int32,
        _ buffer: UnsafeRawPointer,
        _ count: Int
    ) -> Int {
        #if canImport(Darwin)
        Darwin.write(descriptor, buffer, count)
        #else
        Glibc.write(descriptor, buffer, count)
        #endif
    }

    private static func posixError(_ operation: String, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed for \(path)"]
        )
    }
}
