import Darwin
import Foundation
import os.log

final class PowerShellProcessTransport: PowerShellChannelTransport, @unchecked Sendable {
    enum ExecutionMode: Equatable {
        case persistent
        case oneShot
    }

    private static let readTimeoutMilliseconds: Int32 = 30_000

    private let sshTarget: String
    private let controlDirectory: URL
    private let hostTrust: SSHHostTrust
    private let processFactory: @Sendable () -> Process
    private let executionMode: ExecutionMode
    private let stateLock = NSLock()

    private var worker: RemoteProcessWorker?
    private var shutdownFailure: String?
    private let responseTimeout: Duration?
    private static let logger = Logger(subsystem: "com.detours", category: "remote-worker")
    private var dispatcherBase64: String?

    init(
        sshTarget: String,
        controlDirectory: URL,
        hostTrust: SSHHostTrust,
        executionMode: ExecutionMode = .persistent,
        responseTimeout: Duration? = .seconds(10),
        processFactory: @escaping @Sendable () -> Process = { Process() }
    ) {
        self.sshTarget = sshTarget
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.executionMode = executionMode
        self.responseTimeout = responseTimeout
        self.processFactory = processFactory
    }

    func start(dispatcherBase64: String) async throws {
        try hostTrust.prepareKnownHostsFile()
        stateLock.withLock { self.dispatcherBase64 = dispatcherBase64 }
        guard executionMode == .persistent else { return }
        try await startProcess(dispatcherBase64: dispatcherBase64)
    }

    private func startProcess(dispatcherBase64: String) async throws {
        let current = try stateLock.withLock {
            if let shutdownFailure { throw PowerShellChannelError.processFailed(shutdownFailure) }
            if let worker { return worker }
            let process = processFactory()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments(dispatcherBase64: dispatcherBase64)
            let created = RemoteProcessWorker(process: process)
            worker = created
            return created
        }
        try await current.perform { try $0.start() }
    }

    func sendFrame(_ frame: Data) async throws {
        if executionMode == .oneShot {
            guard let dispatcher = stateLock.withLock({ dispatcherBase64 }) else {
                throw PowerShellChannelError.processFailed("PowerShell channel is not connected.")
            }
            try await startProcess(dispatcherBase64: dispatcher)
        }
        let current = try currentWorker()
        let oneShot = executionMode == .oneShot
        do {
            try await current.perform { worker in
                try worker.write(frame)
                if oneShot { worker.closeInput() }
            }
        } catch { throw mapped(error, worker: current) }
    }

    func readFrame() async throws -> Data {
        let current = try currentWorker()
        let timeout = responseTimeout
        do {
            let result = try await current.perform { try $0.readFrame(timeout: timeout) }
            if executionMode == .oneShot { try await retire(current) }
            return result
        } catch { throw mapped(error, worker: current) }
    }

    private func mapped(_ error: Error, worker: RemoteProcessWorker) -> Error {
        guard let failure = error as? RemoteProcessWorkerError else { return error }
        switch failure {
        case .timedOut: return PowerShellChannelError.timeout(failure.localizedDescription)
        case .closed:
            let detail = worker.diagnostics
            return detail.isEmpty ? PowerShellChannelError.unexpectedEOF : PowerShellChannelError.processFailed(detail)
        case .shutdownTimedOut, .system: return PowerShellChannelError.processFailed(failure.localizedDescription)
        }
    }

    static func readFramePayload(from handle: FileHandle) throws -> Data {
        let lengthData = try readExact(4, from: handle)
        let length = Int(UInt32(bigEndianData: lengthData.prefix(4)))
        // A garbage length from a stdout desync must not force a huge allocation; cap it at
        // the same 16 MB ceiling the encoder enforces before reading the payload.
        guard length <= RPCStreamHandler.defaultMaxFrameSize else {
            throw RPCProtocolError.frameTooLarge(length)
        }
        return try readExact(length, from: handle)
    }

    func stop() async {
        guard let current = stateLock.withLock({ worker }) else { return }
        do { try await retire(current) } catch { recordShutdownFailure(error) }
    }

    private func retire(_ current: RemoteProcessWorker) async throws {
        try await current.stop()
        stateLock.withLock {
            if worker === current { worker = nil }
        }
    }

    func closeControlConnection() async {
        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "ControlPath=\(controlDirectory.path)/%C", "-O", "exit", sshTarget]
        let control = RemoteProcessWorker(process: process)
        do {
            try await control.perform { worker in
                try worker.start()
                worker.closeInput()
                while !(try worker.read(maximumBytes: 4_096, timeout: .seconds(10))).isEmpty {}
                _ = try worker.waitForExit()
            }
        } catch { recordShutdownFailure(error) }
    }

    private func recordShutdownFailure(_ error: Error) {
        let message = error.localizedDescription
        stateLock.withLock { shutdownFailure = message }
        Self.logger.error("Remote worker shutdown failed: \(message, privacy: .public)")
    }

    private func currentWorker() throws -> RemoteProcessWorker {
        try stateLock.withLock {
            if let shutdownFailure { throw PowerShellChannelError.processFailed(shutdownFailure) }
            guard let worker else { throw PowerShellChannelError.processFailed("PowerShell channel is not connected.") }
            return worker
        }
    }

    /// Terminates a process without ever blocking indefinitely. A plain `waitUntilExit()` after
    /// `terminate()` deadlocks the channel forever when a wedged ssh ignores SIGTERM (e.g. stuck
    /// on a degraded host), so escalate to SIGKILL after a short grace and bound every wait.
    static func terminatePromptly(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        if waitForExit(process, within: 0.5) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(process, within: 0.5)
    }

    private static func waitForExit(_ process: Process, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }

    private func sshArguments(dispatcherBase64: String) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
            // Keep the multiplexed master alive after a oneShot request exits so terminating
            // it cannot drop a watch or transfer connection sharing the same control path.
            "-o", "ControlPersist=300",
        ] + hostTrust.sshArguments + [
            sshTarget,
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            dispatcherBase64,
        ]
    }

    private static func readExact(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        let fileDescriptor = handle.fileDescriptor
        while result.count < count {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, readTimeoutMilliseconds)
            if pollResult == 0 {
                throw PowerShellChannelError.timeout("Timed out waiting for Windows PowerShell response.")
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw PowerShellChannelError.processFailed(String(cString: strerror(errno)))
            }
            if descriptor.revents & Int16(POLLIN) == 0 {
                throw PowerShellChannelError.unexpectedEOF
            }

            let remaining = count - result.count
            var buffer = [UInt8](repeating: 0, count: remaining)
            let byteCount = Darwin.read(fileDescriptor, &buffer, remaining)
            if byteCount > 0 {
                result.append(buffer, count: byteCount)
            } else if byteCount == 0 {
                throw PowerShellChannelError.unexpectedEOF
            } else if errno != EINTR {
                throw PowerShellChannelError.processFailed(String(cString: strerror(errno)))
            }
        }
        return result
    }
}
