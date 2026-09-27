import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension OperationDirectory {
    /// Only for the explicitly confirmed permanent-delete action, never scratch cleanup or undo.
    public func deleteImmediately(_ name: Data, expected: OperationObservation) throws {
        try requireCurrentPath()
        let current = try observe(name)
        guard current.identity == expected.identity, current.kind == expected.kind,
              current.linkTarget == expected.linkTarget,
              current.kind == .directory || current.version == expected.version else {
            throw OperationFilesystemError.identityChanged
        }
        let flags = current.kind == .directory ? AT_REMOVEDIR : 0
        let result = try Self.withBytes(name) { unlinkat(descriptor, $0, flags) }
        guard result == 0 else { throw Self.systemError() }
        try synchronize()
    }
}
