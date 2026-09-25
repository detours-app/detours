import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension OperationDirectory {
    public func copyMetadata(to destination: OperationDirectory) throws {
        try requireCurrentPath()
        try destination.requireCurrentPath()
        #if canImport(Darwin)
        guard fcopyfile(descriptor, destination.descriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw Self.systemError()
        }
        #else
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              fchmod(destination.descriptor, information.st_mode & ~mode_t(S_IFMT)) == 0 else {
            throw Self.systemError()
        }
        var times = [information.st_atim, information.st_mtim]
        guard futimens(destination.descriptor, &times) == 0 else { throw Self.systemError() }
        #endif
        try destination.synchronize()
        try requireCurrentPath()
        try destination.requireCurrentPath()
    }
}
