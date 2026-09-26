import Darwin
import Foundation

final class SSHConnectionDiagnostics: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var bytes = Data()
    private var ended = false

    init(pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] _ in _ = self?.snapshot() }
    }

    deinit { handle.readabilityHandler = nil }

    func snapshot() -> String {
        let result = lock.withLock { () -> (String, Bool) in
            guard !ended else { return (String(data: bytes, encoding: .utf8) ?? "", true) }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            for _ in 0..<16 {
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { break }
                let count = Darwin.read(handle.fileDescriptor, &buffer, 4_096)
                if count == 0 { ended = true; break }
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
                if bytes.count > 16_384 { bytes.removeFirst(bytes.count - 16_384) }
            }
            return (String(data: bytes, encoding: .utf8) ?? "", ended)
        }
        if result.1 { handle.readabilityHandler = nil }
        return result.0
    }
}
