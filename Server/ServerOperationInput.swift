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
    case sourceFile(FileHandle, OperationDirectory, Data, OperationObservation)

    func next(offset: UInt64, expected: UInt64, cancelled: () throws -> Bool) throws -> Data {
        switch self {
        case .contents(let contents):
            guard offset < UInt64(contents.count) else { return Data() }
            let start = Int(offset)
            return contents.subdata(in: start..<min(contents.count, start + 64 * 1024))
        case .stream(let handle), .sourceFile(let handle, _, _, _):
            guard offset < expected else { return Data() }
            let maximum = Int(min(UInt64(64 * 1024), expected - offset))
            return try readChunk(handle, maximum: maximum, cancelled: cancelled)
        }
    }

    func validateSource() throws {
        guard case .sourceFile(_, let directory, let name, let expected) = self else { return }
        try directory.requireCurrentPath()
        let current = try directory.observe(name)
        guard current.identity == expected.identity, current.version == expected.version else {
            throw OperationFilesystemError.identityChanged
        }
    }

    func copyMetadata(to output: FileHandle) throws {
        guard case .sourceFile(let source, _, _, _) = self else { return }
        try validateSource()
        #if canImport(Darwin)
        guard fcopyfile(source.fileDescriptor, output.fileDescriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw OperationFilesystemError.system(errno)
        }
        #else
        var information = stat()
        guard fstat(source.fileDescriptor, &information) == 0,
              fchmod(output.fileDescriptor, information.st_mode & ~mode_t(S_IFMT)) == 0 else {
            throw OperationFilesystemError.system(errno)
        }
        #endif
        try validateSource()
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
