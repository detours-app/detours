import Darwin
import Foundation

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

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var dispatcherBase64: String?

    init(
        sshTarget: String,
        controlDirectory: URL,
        hostTrust: SSHHostTrust,
        executionMode: ExecutionMode = .persistent,
        processFactory: @escaping @Sendable () -> Process = { Process() }
    ) {
        self.sshTarget = sshTarget
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.executionMode = executionMode
        self.processFactory = processFactory
    }

    func start(dispatcherBase64: String) async throws {
        try hostTrust.prepareKnownHostsFile()
        self.dispatcherBase64 = dispatcherBase64
        guard executionMode == .persistent else { return }
        try startProcess(dispatcherBase64: dispatcherBase64)
    }

    private func startProcess(dispatcherBase64: String) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard process == nil else { return }
        let process = processFactory()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(dispatcherBase64: dispatcherBase64)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            ProcessRetirement.retireOnMain(process)
            throw error
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
    }

    func sendFrame(_ frame: Data) async throws {
        if executionMode == .oneShot {
            guard let dispatcherBase64 else {
                throw PowerShellChannelError.processFailed("PowerShell channel is not connected.")
            }
            try startProcess(dispatcherBase64: dispatcherBase64)
        }
        let (_, stdinPipe) = try processForWriting()
        try await Task.detached(priority: .userInitiated) {
            try Self.writeFramePayload(frame, to: stdinPipe.fileHandleForWriting)
        }.value
        if executionMode == .oneShot {
            stdinPipe.fileHandleForWriting.closeFile()
            clearStdinPipeIfCurrent(stdinPipe)
        }
    }

    func readFrame() async throws -> Data {
        let (runningProcess, stdoutPipe) = try processForReading()
        let output = stdoutPipe.fileHandleForReading
        defer {
            if executionMode == .oneShot {
                stopProcess()
            }
        }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try withExtendedLifetime((runningProcess, stdoutPipe)) {
                    try Self.readFramePayload(from: output)
                }
            }.value
        } catch {
            if executionMode == .persistent {
                stopProcess()
            }
            throw error
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
        stopProcess()
    }

    func closeControlConnection() async {
        // Ask the multiplexing master at this host's ControlPath to exit now. Because the
        // command, transfer, and watch channels share one socket, a single exit request ends
        // them all — including long-lived watcher processes — instead of leaving them orphaned
        // until ControlPersist expires. Best effort: a missing master just exits nonzero.
        let controlPath = "\(controlDirectory.path)/%C"
        let target = sshTarget
        let factory = processFactory
        await Task.detached(priority: .userInitiated) {
            let process = factory()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "ControlPath=\(controlPath)", "-O", "exit", target]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            ProcessRetirement.retireOnMain(process)
        }.value
    }

    private func stopProcess() {
        stateLock.lock()
        let runningProcess = process
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stateLock.unlock()
        Self.terminatePromptly(runningProcess)
        ProcessRetirement.retireOnMain(runningProcess)
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

    private func processForWriting() throws -> (Process, Pipe) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runningProcess = process, runningProcess.isRunning, let stdinPipe else {
            throw PowerShellChannelError.processFailed("PowerShell channel is not connected.")
        }
        return (runningProcess, stdinPipe)
    }

    private func processForReading() throws -> (Process, Pipe) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runningProcess = process, let stdoutPipe else {
            throw PowerShellChannelError.processFailed("PowerShell channel is not connected.")
        }
        return (runningProcess, stdoutPipe)
    }

    private func clearStdinPipeIfCurrent(_ pipe: Pipe) {
        stateLock.lock()
        if stdinPipe === pipe {
            stdinPipe = nil
        }
        stateLock.unlock()
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
