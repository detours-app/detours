import Foundation

/// Wraps `copyfile(3)` with a 1 MB buffer for better throughput on fast storage.
/// Reports byte-level progress via callback during copy.
enum CopyfileHelper {
    /// Progress callback: (cumulativeBytesCopied) -> shouldContinue
    typealias ProgressHandler = @Sendable (_ bytesCopied: Int64) -> Bool

    /// Copy a single file or directory using `copyfile(3)` with optimized buffer size.
    static func copy(from source: URL, to destination: URL, progress: ProgressHandler? = nil) throws {
        let partial = partialURL(for: destination)
        try? FileManager.default.removeItem(at: partial)
        let state = copyfile_state_alloc()
        defer {
            copyfile_state_free(state)
            try? FileManager.default.removeItem(at: partial)
        }

        var bufferSize: off_t = 1_048_576
        copyfile_state_set(state, UInt32(COPYFILE_STATE_BSIZE), &bufferSize)

        let context = UnsafeMutablePointer<CopyContext>.allocate(capacity: 1)
        context.initialize(to: CopyContext(progress: progress, cancelled: false, baseOffset: 0, lastRawBytes: 0))
        defer {
            context.deinitialize(count: 1)
            context.deallocate()
        }

        if progress != nil {
            let callbackPtr = unsafeBitCast(progressCallback as copyfile_callback_t, to: UnsafeRawPointer.self)
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPtr)
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context)
        }

        var flags = copyfile_flags_t(COPYFILE_ALL)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            flags |= copyfile_flags_t(COPYFILE_RECURSIVE)
        }

        let result = source.path.withCString { src in
            partial.path.withCString { dst in
                copyfile(src, dst, state, flags)
            }
        }

        if context.pointee.cancelled {
            throw FileOperationError.cancelled
        }

        if result != 0 {
            let posixError = errno

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

        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).detours-copy-partial-\(UUID().uuidString)")
    }
}

// MARK: - Private

private struct CopyContext {
    var progress: CopyfileHelper.ProgressHandler?
    var cancelled: Bool
    /// Sum of all previously completed files' bytes
    var baseOffset: Int64
    /// Last raw value from COPYFILE_STATE_COPIED (resets per file in recursive copies)
    var lastRawBytes: Int64
}

private let progressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }

    let context = ctx.assumingMemoryBound(to: CopyContext.self)

    if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
        var rawBytes: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &rawBytes)

        // Detect per-file reset: rawBytes dropped below previous value
        if rawBytes < context.pointee.lastRawBytes {
            // Previous file finished — add its final size to base
            context.pointee.baseOffset += context.pointee.lastRawBytes
        }
        context.pointee.lastRawBytes = rawBytes

        let cumulative = context.pointee.baseOffset + rawBytes

        if let handler = context.pointee.progress {
            if !handler(cumulative) {
                context.pointee.cancelled = true
                return COPYFILE_QUIT
            }
        }
    }

    return COPYFILE_CONTINUE
}
