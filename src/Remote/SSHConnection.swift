import Foundation

enum SSHConnectionError: Error, Equatable {
    case notConnected
    case unexpectedEOF
    case invalidControlDirectory(URL)
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
    private var frameReader = RPCStreamHandler()
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
                await self.processExited(process.terminationStatus)
            }
        }

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        transition(to: .connected)
        scheduleIdleDisconnectIfNeeded()
    }

    func disconnect() {
        cancelIdleDisconnect()
        disconnectedForIdle = false
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        frameReader = RPCStreamHandler()
        transition(to: .disconnected)
    }

    func send(_ envelope: RPCEnvelope) async throws {
        if disconnectedForIdle {
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

        while true {
            let chunk = stdoutPipe.fileHandleForReading.readData(ofLength: 4096)
            guard !chunk.isEmpty else {
                throw SSHConnectionError.unexpectedEOF
            }

            let frames = try frameReader.append(chunk)
            if let frame = frames.first {
                return try RPCEnvelope(encodedPayload: frame)
            }
        }
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

    private func processExited(_ status: Int32) {
        cancelIdleDisconnect()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil

        guard state != .disconnected else { return }
        transition(to: .failed(reason: .processExited(status)))
    }

    private func disconnectAfterFailure(_ reason: SSHConnectionFailureReason) {
        cancelIdleDisconnect()
        disconnectedForIdle = false
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        frameReader = RPCStreamHandler()
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
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        frameReader = RPCStreamHandler()
        disconnectedForIdle = true
        transition(to: .disconnected)
    }

    #if DEBUG
    func simulateConnectedForTesting() {
        transition(to: .connected)
        scheduleIdleDisconnectIfNeeded()
    }

    func isDisconnectedForIdleForTesting() -> Bool {
        disconnectedForIdle
    }

    func prepareControlDirectoryForTesting() throws {
        try prepareControlDirectory()
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
        NotificationCenter.default.post(name: .sshConnectionStateDidChange, object: change)
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
}
