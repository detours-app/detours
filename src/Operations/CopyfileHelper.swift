import Foundation

/// Wraps `copyfile(3)` with a 1 MB buffer for better throughput on fast storage.
/// Reports byte-level progress via callback during copy.
enum CopyfileHelper {
    /// Progress callback: (bytesCopied) -> shouldContinue
    typealias ProgressHandler = @Sendable (_ bytesCopied: Int64) -> Bool

    /// Copy a single file or directory using `copyfile(3)` with optimized buffer size.
    /// - Parameters:
    ///   - source: Source file or directory URL
    ///   - destination: Destination URL (must not exist)
    ///   - progress: Optional callback reporting cumulative bytes copied. Return `false` to cancel.
    /// - Throws: On copy failure or cancellation
    static func copy(from source: URL, to destination: URL, progress: ProgressHandler? = nil) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }

        // Set 1 MB buffer for better throughput (default is 64 KB)
        var bufferSize: off_t = 1_048_576
        copyfile_state_set(state, UInt32(COPYFILE_STATE_BSIZE), &bufferSize)

        // Store progress handler context
        let context = UnsafeMutablePointer<CopyContext>.allocate(capacity: 1)
        context.initialize(to: CopyContext(progress: progress, cancelled: false, bytesCopied: 0))
        defer {
            context.deinitialize(count: 1)
            context.deallocate()
        }

        // Set up progress callback
        if progress != nil {
            let callbackPtr = unsafeBitCast(
                progressCallback as copyfile_callback_t,
                to: UnsafeRawPointer.self
            )
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPtr)
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context)
        }

        // Determine flags
        var flags = copyfile_flags_t(COPYFILE_ALL)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            flags |= copyfile_flags_t(COPYFILE_RECURSIVE)
        }

        let result = source.path.withCString { src in
            destination.path.withCString { dst in
                copyfile(src, dst, state, flags)
            }
        }

        if context.pointee.cancelled {
            // Clean up partial file on cancellation
            try? FileManager.default.removeItem(at: destination)
            throw FileOperationError.cancelled
        }

        if result != 0 {
            let posixError = errno
            // Clean up partial file on error
            try? FileManager.default.removeItem(at: destination)

            switch posixError {
            case EACCES, EPERM:
                throw FileOperationError.permissionDenied(destination)
            case ENOSPC:
                throw FileOperationError.diskFull
            default:
                throw FileOperationError.unknown(
                    NSError(domain: NSPOSIXErrorDomain, code: Int(posixError))
                )
            }
        }
    }
}

// MARK: - Private

private struct CopyContext {
    var progress: CopyfileHelper.ProgressHandler?
    var cancelled: Bool
    var bytesCopied: Int64
}

private let progressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }

    let context = ctx.assumingMemoryBound(to: CopyContext.self)

    if what == COPYFILE_COPY_DATA {
        if stage == COPYFILE_PROGRESS {
            var bytesCopied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytesCopied)
            context.pointee.bytesCopied = bytesCopied

            if let handler = context.pointee.progress {
                if !handler(bytesCopied) {
                    context.pointee.cancelled = true
                    return COPYFILE_QUIT
                }
            }
        }
    }

    return COPYFILE_CONTINUE
}
