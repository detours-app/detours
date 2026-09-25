import Foundation
import RemoteOperationSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ServerOperationInput: Sendable {
    case contents(Data)
    case stream(FileHandle)

    func next(offset: UInt64, expected: UInt64, cancelled: () throws -> Bool) throws -> Data {
        switch self {
        case .contents(let contents):
            guard offset < UInt64(contents.count) else { return Data() }
            let start = Int(offset)
            return contents.subdata(in: start..<min(contents.count, start + 64 * 1024))
        case .stream(let handle):
            guard offset < expected else { return Data() }
            let maximum = Int(min(UInt64(64 * 1024), expected - offset))
            return try readChunk(handle, maximum: maximum, cancelled: cancelled)
        }
    }

    private func readChunk(_ handle: FileHandle, maximum: Int, cancelled: () throws -> Bool) throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while true {
            guard try !cancelled() else { throw OperationContractError.cancelled }
            guard clock.now < deadline else { throw OperationJournalError.busy }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let available = poll(&descriptor, 1, 200)
            if available == 0 { continue }
            if available < 0 {
                if errno == EINTR { continue }
                throw OperationFilesystemError.system(errno)
            }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw OperationFilesystemError.system(EBADF) }
            var data = Data(count: maximum)
            let count = data.withUnsafeMutableBytes { buffer in
                read(handle.fileDescriptor, buffer.baseAddress, maximum)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw OperationFilesystemError.system(errno)
            }
            data.count = count
            return data
        }
    }
}
