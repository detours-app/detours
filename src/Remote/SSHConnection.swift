import Foundation

enum SSHConnectionError: Error, Equatable, LocalizedError {
    case notConnected
    case unexpectedEOF
    case invalidControlDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The SSH helper is not connected."
        case .unexpectedEOF:
            return "The SSH helper closed the connection before sending a complete response."
        case .invalidControlDirectory(let url):
            return "The SSH control socket directory is invalid: \(url.path)"
        }
    }
}

struct SSHConnectionConfiguration: Equatable, Sendable {
    let hostID: UUID
    let sshTarget: String
    let remoteCommand: String

    init(hostID: UUID, sshTarget: String, remoteCommand: String = "~/.detours-server/detours-server") {
        self.hostID = hostID
        self.sshTarget = sshTarget
        self.remoteCommand = remoteCommand
    }
}

actor SSHConnection {
    private let configuration: SSHConnectionConfiguration
    private let controlDirectory: URL
    private let hostTrust: SSHHostTrust
    private let askPassBridge: SSHAskPassBridge
    private let processFactory: @Sendable () -> Process
    private let idleTimeout: TimeInterval

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lastStderr = ""
    private var frameReader = RPCStreamHandler()
    private var streamGeneration: UInt64 = 0
    private var activePaneCount = 0
    private var inFlightOperationCount = 0
    private var activeWatchCount = 0
    private var disconnectedForIdle = false
    private var idleDisconnectTask: Task<Void, Never>?

    private(set) var state: SSHConnectionState = .disconnected {
        didSet {
            publishStateChange(from: oldValue, to: state)
        }
    }

    init(
        configuration: SSHConnectionConfiguration,
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust(),
        askPassBridge: SSHAskPassBridge = SSHAskPassBridge(),
        idleTimeout: TimeInterval = 5 * 60,
        processFactory: @escaping @Sendable () -> Process = { Process() }
    ) {
        self.configuration = configuration
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.askPassBridge = askPassBridge
        self.idleTimeout = idleTimeout
        self.processFactory = processFactory
    }

    deinit {
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func connect() async throws {
        guard process == nil else { return }
        cancelIdleDisconnect()
        disconnectedForIdle = false

        transition(to: .connecting)
        try prepareControlDirectory()
        try hostTrust.prepareKnownHostsFile()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if !askPassBridge.environment().isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(askPassBridge.environment()) { _, new in new }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            Task {
                await self.processExited(process, status: process.terminationStatus)
            }
        }

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        streamGeneration += 1
        transition(to: .connected)
        scheduleIdleDisconnectIfNeeded()
    }

    func forceReconnect() async throws {
        disconnect()
        try await connect()
    }

    func disconnect() {
        cancelIdleDisconnect()
        disconnectedForIdle = false
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        frameReader = RPCStreamHandler()
        streamGeneration += 1
        transition(to: .disconnected)
    }

    func send(_ envelope: RPCEnvelope) async throws {
        if disconnectedForIdle || state == .disconnected {
            try await connect()
        }

        guard let stdinPipe else {
            throw SSHConnectionError.notConnected
        }

        let frame = try RPCStreamHandler.encodeFrame(envelope.encodedPayload())
        stdinPipe.fileHandleForWriting.write(frame)
    }

    func setActivePaneCount(_ count: Int) {
        activePaneCount = max(0, count)
        scheduleIdleDisconnectIfNeeded()
    }

    func beginInFlightOperation() {
        inFlightOperationCount += 1
        scheduleIdleDisconnectIfNeeded()
    }

    func endInFlightOperation() {
        inFlightOperationCount = max(0, inFlightOperationCount - 1)
        scheduleIdleDisconnectIfNeeded()
    }

    func registerActiveWatch() {
        activeWatchCount += 1
        scheduleIdleDisconnectIfNeeded()
    }

    func unregisterActiveWatch() {
        activeWatchCount = max(0, activeWatchCount - 1)
        scheduleIdleDisconnectIfNeeded()
    }

    func receive() async throws -> RPCEnvelope {
        guard let stdoutPipe else {
            throw SSHConnectionError.notConnected
        }

        let output = stdoutPipe.fileHandleForReading
        let frame = try await Task.detached(priority: .userInitiated) {
            try Self.readFrame(from: output)
        }.value
        return try RPCEnvelope(encodedPayload: frame)
    }

    func reconnect(afterFailure reason: SSHConnectionFailureReason) async {
        disconnectAfterFailure(reason)
        guard SSHReconnectPolicy.isRetryable(reason) else { return }

        var elapsed: TimeInterval = 0
        var attempt = 1

        while let delay = SSHReconnectPolicy.delay(forAttempt: attempt),
              SSHReconnectPolicy.shouldContinue(afterElapsed: elapsed, nextDelay: delay) {
            transition(to: .reconnecting(attempt: attempt, nextDelay: delay))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            elapsed += delay

            do {
                try await connect()
                return
            } catch {
                attempt += 1
            }
        }

        transition(to: .failed(reason: reason))
    }

    private func processExited(_ exitedProcess: Process, status: Int32) {
        guard process === exitedProcess else { return }
        cancelIdleDisconnect()
        lastStderr = stderrPipe.flatMap {
            String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } ?? ""
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        guard state != .disconnected else { return }
        streamGeneration += 1
        let reason = SSHConnectionFailureReason.processExited(status)
        if hasIdleBlockers, SSHReconnectPolicy.isRetryable(reason) {
            Task { [weak self] in
                await self?.reconnect(afterFailure: reason)
            }
            return
        }
        transition(to: .failed(reason: reason))
    }

    private func disconnectAfterFailure(_ reason: SSHConnectionFailureReason) {
        cancelIdleDisconnect()
        disconnectedForIdle = false
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        frameReader = RPCStreamHandler()
        streamGeneration += 1
        transition(to: .failed(reason: reason))
    }

    private func transition(to newState: SSHConnectionState) {
        guard state != newState else { return }
        state = newState
    }

    private var hasIdleBlockers: Bool {
        activePaneCount > 0 || inFlightOperationCount > 0 || activeWatchCount > 0
    }

    private func scheduleIdleDisconnectIfNeeded() {
        cancelIdleDisconnect()
        guard state == .connected, !hasIdleBlockers else { return }

        let timeout = idleTimeout
        idleDisconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            await self?.disconnectForIdleIfStillInactive()
        }
    }

    private func cancelIdleDisconnect() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = nil
    }

    private func disconnectForIdleIfStillInactive() {
        guard state == .connected, !hasIdleBlockers else { return }
        idleDisconnectTask = nil
        disconnectedForIdle = true
        transition(to: .disconnected)
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        frameReader = RPCStreamHandler()
        streamGeneration += 1
    }

    #if DEBUG
    func streamGenerationForTesting() -> UInt64 {
        streamGeneration
    }

    func simulateConnectedForTesting() {
        transition(to: .connected)
        scheduleIdleDisconnectIfNeeded()
    }

    func isDisconnectedForIdleForTesting() -> Bool {
        disconnectedForIdle
    }

    func lastStderrForTesting() -> String {
        lastStderr
    }

    func prepareControlDirectoryForTesting() throws {
        try prepareControlDirectory()
    }

    func simulateProcessForTesting() {
        process = Process()
    }

    func simulateStdoutPipeForTesting(_ pipe: Pipe) {
        process = Process()
        stdoutPipe = pipe
        streamGeneration += 1
        transition(to: .connected)
    }

    func simulateReconnectForTesting(
        afterFailure reason: SSHConnectionFailureReason,
        maximumTotalDelay: TimeInterval = SSHReconnectPolicy.maximumTotalDelay,
        connectAttempt: @Sendable (Int) async throws -> Void
    ) async -> [SSHConnectionState] {
        var observed: [SSHConnectionState] = []
        func record(_ state: SSHConnectionState) {
            transition(to: state)
            observed.append(state)
        }

        disconnectAfterFailure(reason)
        observed.append(state)
        guard SSHReconnectPolicy.isRetryable(reason) else { return observed }

        var elapsed: TimeInterval = 0
        var attempt = 1
        while let delay = SSHReconnectPolicy.delay(forAttempt: attempt),
              elapsed + delay <= maximumTotalDelay {
            record(.reconnecting(attempt: attempt, nextDelay: delay))
            elapsed += delay
            do {
                try await connectAttempt(attempt)
                record(.connected)
                return observed
            } catch {
                attempt += 1
            }
        }

        record(.failed(reason: reason))
        return observed
    }
    #endif

    private func publishStateChange(from oldState: SSHConnectionState, to newState: SSHConnectionState) {
        let change = SSHConnectionStateChange(
            hostID: configuration.hostID,
            oldState: oldState,
            newState: newState
        )
        Task { @MainActor in
            NotificationCenter.default.post(name: .sshConnectionStateDidChange, object: change)
        }
    }

    private func prepareControlDirectory() throws {
        try FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory.path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: controlDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SSHConnectionError.invalidControlDirectory(controlDirectory)
        }
    }

    private func sshArguments() -> [String] {
        [
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
        ] + hostTrust.sshArguments + [
            configuration.sshTarget,
            configuration.remoteCommand,
        ]
    }

    func currentStreamGeneration() -> UInt64 {
        streamGeneration
    }

    private static func readFrame(from output: FileHandle) throws -> Data {
        let lengthBytes = output.readData(ofLength: 4)
        guard lengthBytes.count == 4 else {
            throw SSHConnectionError.unexpectedEOF
        }
        let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        // A malicious or malfunctioning server could declare a multi-gigabyte frame; cap it at the
        // same 16 MB ceiling the encoder enforces so a bad length field can't force a huge allocation.
        guard length <= RPCStreamHandler.defaultMaxFrameSize else {
            throw RPCProtocolError.frameTooLarge(length)
        }
        let payload = output.readData(ofLength: length)
        guard payload.count == length else {
            throw SSHConnectionError.unexpectedEOF
        }
        return payload
    }
}
