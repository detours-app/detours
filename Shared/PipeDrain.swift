import Foundation

/// Reads a pipe to EOF on a background thread.
///
/// A child process writing more than the pipe buffer holds blocks on `write()` until someone
/// reads. Calling `waitUntilExit()` before reading therefore deadlocks: the parent waits for the
/// child to exit, the child waits for the parent to read. Start the drain before waiting.
public final class PipeDrain: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    public static func start(reading handle: FileHandle) -> PipeDrain {
        let drain = PipeDrain()
        let thread = Thread {
            let read = handle.readDataToEndOfFile()
            drain.finish(with: read)
        }
        thread.start()
        return drain
    }

    private func finish(with data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
        semaphore.signal()
    }

    /// Blocks until the pipe reaches EOF, then returns everything it carried.
    public func wait() -> Data {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
