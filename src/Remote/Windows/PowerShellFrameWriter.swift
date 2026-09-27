import Darwin
import Foundation

extension PowerShellProcessTransport {
    static func writeFramePayload(_ frame: Data, to handle: FileHandle, timeoutMilliseconds: Int32 = 30_000) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        let noSignal = fcntl(descriptor, F_GETNOSIGPIPE)
        guard flags >= 0, noSignal >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw PowerShellChannelError.processFailed(String(cString: strerror(errno)))
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw PowerShellChannelError.processFailed(String(cString: strerror(errno)))
        }
        defer { _ = fcntl(descriptor, F_SETNOSIGPIPE, noSignal) }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMilliseconds) / 1_000
        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    throw PowerShellChannelError.timeout("Timed out sending Windows PowerShell request.")
                }
                var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&readiness, 1, Int32(min(Double(Int32.max), ceil(remaining * 1_000))))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw PowerShellChannelError.processFailed(String(cString: strerror(errno)))
                }
                if ready == 0 { continue }
                guard readiness.revents & Int16(POLLOUT) != 0 else {
                    throw PowerShellChannelError.unexpectedEOF
                }
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    throw PowerShellChannelError.processFailed(String(cString: strerror(errno)))
                }
            }
        }
    }
}
