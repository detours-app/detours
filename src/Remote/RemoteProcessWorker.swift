import Darwin
import Foundation

enum RemoteProcessWorkerError: Error, LocalizedError, Sendable {
    case timedOut
    case shutdownTimedOut
    case closed
    case system(Int32)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The remote process stopped making progress."
        case .shutdownTimedOut: return "The remote process did not stop within the shutdown deadline."
        case .closed: return "The remote process closed its input or output."
        case .system(let code): return String(cString: strerror(code))
        }
    }
}

final class RemoteProcessWorker: @unchecked Sendable {
    let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostic = Pipe()
    private let lock = NSLock()
    private let inputLock = NSLock()
    private let shutdown = DispatchGroup()
    private let diagnosticsFinished = DispatchGroup()
    private var started = false
    private var stopping = false
    private var inputClosed = false
    private var diagnosticBytes = Data()
    private let clock = ContinuousClock()

    init(process: Process) {
        self.process = process
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostic
    }

    func start() throws {
        let didStart = try lock.withLock {
            guard !stopping else { throw CancellationError() }
            guard !started else { return false }
            try Self.makeNonblocking(input.fileHandleForWriting)
            try Self.makeNonblocking(output.fileHandleForReading)
            try Self.makeNonblocking(diagnostic.fileHandleForReading)
            try process.run()
            started = true
            diagnosticsFinished.enter()
            return true
        }
        guard didStart else { return }
        DispatchQueue.global(qos: .utility).async { self.drainDiagnostics() }
    }

    func perform<Value: Sendable>(_ body: @escaping @Sendable (RemoteProcessWorker) throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.checkCancellation()
                        let result = try body(self)
                        try self.checkCancellation()
                        continuation.resume(returning: result)
                    } catch {
                        self.requestStop()
                        do {
                            try self.waitForShutdown()
                            continuation.resume(throwing: error)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            self.requestStop()
        }
    }

    func requestStop() {
        let launch = lock.withLock {
            guard !stopping else { return false }
            stopping = true
            shutdown.enter()
            return true
        }
        guard launch else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.shutdown.leave() }
            self.closeInput()
            guard self.lock.withLock({ self.started }) else { return }
            if self.waitUntilExit(within: .seconds(2)) { return }
            if self.process.isRunning { self.process.terminate() }
            if self.waitUntilExit(within: .seconds(1)) { return }
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            _ = self.waitUntilExit(within: .seconds(2))
        }
    }

    func stop() async throws {
        requestStop()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try self.waitForShutdown(); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func waitForShutdown() throws {
        guard shutdown.wait(timeout: .now() + 5) == .success else { throw RemoteProcessWorkerError.shutdownTimedOut }
        guard !lock.withLock({ started }) || !process.isRunning else { throw RemoteProcessWorkerError.shutdownTimedOut }
    }

    func closeInput() {
        inputLock.withLock {
            guard !inputClosed else { return }
            inputClosed = true
            try? input.fileHandleForWriting.close()
        }
    }

    func write(_ data: Data, timeout: Duration = .seconds(10)) throws {
        try inputLock.withLock {
            guard !inputClosed else { throw RemoteProcessWorkerError.closed }
            let deadline = clock.now.advanced(by: timeout)
            let descriptor = input.fileHandleForWriting.fileDescriptor
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                    let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    throw RemoteProcessWorkerError.system(errno)
                }
            }
        }
    }

    func read(maximumBytes: Int, timeout: Duration? = .seconds(30)) throws -> Data {
        try read(maximumBytes: maximumBytes, deadline: timeout.map { clock.now.advanced(by: $0) })
    }

    func readExactly(_ count: Int, timeout: Duration? = .seconds(10)) throws -> Data {
        let deadline = timeout.map { clock.now.advanced(by: $0) }
        var result = Data()
        while result.count < count {
            let chunk = try read(maximumBytes: min(count - result.count, 65_536), deadline: deadline)
            guard !chunk.isEmpty else { throw RemoteProcessWorkerError.closed }
            result.append(chunk)
        }
        return result
    }

    private func read(maximumBytes: Int, deadline: ContinuousClock.Instant?) throws -> Data {
        precondition(maximumBytes > 0)
        let descriptor = output.fileHandleForReading.fileDescriptor
        var bytes = Data(count: maximumBytes)
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count >= 0 { bytes.count = count; return bytes }
            if errno == EINTR || errno == EAGAIN { continue }
            throw RemoteProcessWorkerError.system(errno)
        }
    }

    func waitForExit(timeout: Duration = .seconds(10)) throws -> Int32 {
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning {
            try checkCancellation()
            guard clock.now < deadline else { throw RemoteProcessWorkerError.timedOut }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try checkCancellation()
        return process.terminationStatus
    }

    var diagnostics: String {
        // A bounded diagnostic tail can begin inside a UTF-8 scalar; preserve the readable remainder.
        // swiftlint:disable:next optional_data_string_conversion
        lock.withLock { String(decoding: [UInt8](diagnosticBytes), as: UTF8.self) }
    }

    func finishDiagnostics() {
        _ = diagnosticsFinished.wait(timeout: .now() + 1)
    }

    private func checkCancellation() throws {
        if lock.withLock({ stopping }) { throw CancellationError() }
    }

    private func wait(_ descriptor: Int32, events: Int16, deadline: ContinuousClock.Instant?) throws {
        while true {
            try checkCancellation()
            if let deadline, clock.now >= deadline { throw RemoteProcessWorkerError.timedOut }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, 50)
            if result > 0 {
                if item.revents & Int16(POLLNVAL) != 0 { throw RemoteProcessWorkerError.closed }
                return
            }
            if result < 0, errno != EINTR { throw RemoteProcessWorkerError.system(errno) }
        }
    }

    private func waitUntilExit(within duration: Duration) -> Bool {
        let deadline = clock.now.advanced(by: duration)
        while process.isRunning {
            if clock.now >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    private func drainDiagnostics() {
        defer { diagnosticsFinished.leave() }
        let descriptor = diagnostic.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&item, 1, 50)
            if result == 0 {
                if !process.isRunning { return }
                continue
            }
            if result < 0 {
                if errno == EINTR { continue }
                return
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return
            }
            lock.withLock {
                diagnosticBytes.append(contentsOf: buffer.prefix(count))
                if diagnosticBytes.count > 16_384 { diagnosticBytes.removeFirst(diagnosticBytes.count - 16_384) }
            }
        }
    }

    private static func makeNonblocking(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw RemoteProcessWorkerError.system(errno) }
    }

    deinit { ProcessRetirement.retireOnMain(process) }
}
