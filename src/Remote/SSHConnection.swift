import Foundation
import os.log

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
    private var worker: RemoteProcessWorker?
    private var retiredDiagnostics: RemoteProcessWorker?
    private var retirementFailure: String?
    private static let logger = Logger(subsystem: "com.detours", category: "remote-worker")
    private var lastStderr = ""
    private var streamGeneration: UInt64 = 0
    private var activePaneCount = 0
    private var disconnectedForIdle = false
    private var sessionManaged = false
    private var sessionFailure: (@Sendable (SSHConnectionFailureReason) async -> Void)?
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
        _ = BrokenPipe.ignored
    }

    deinit {
        let runningProcess = process
        runningProcess?.terminationHandler = nil
        worker?.requestStop()
        ProcessRetirement.retireOnMain(runningProcess)
    }

    func connect() async throws {
        if let retirementFailure { throw SSHProcessFailure(message: retirementFailure) }
        guard process == nil else { return }
        cancelIdleDisconnect()
        disconnectedForIdle = false

        transition(to: .connecting)
        try prepareControlDirectory()
        try hostTrust.prepareKnownHostsFile()

        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments()
        let current = RemoteProcessWorker(process: process)
        if !askPassBridge.environment().isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(askPassBridge.environment()) { _, new in new }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            Task {
                await self.processExited(process, status: process.terminationStatus)
            }
        }

        self.process = process
        worker = current
        retiredDiagnostics = nil
        do {
            try await current.perform { try $0.start() }
            guard worker === current else { throw SSHConnectionError.notConnected }
        } catch {
            if worker === current { _ = retireCurrentProcess(terminate: true) }
            throw error
        }
        streamGeneration += 1
        transition(to: .connected)
        scheduleIdleDisconnectIfNeeded()
    }

    func forceReconnect() async throws {
        await disconnect()
        try await connect()
    }

    func manageBySession(onFailure: @escaping @Sendable (SSHConnectionFailureReason) async -> Void) {
        sessionManaged = true
        sessionFailure = onFailure
        cancelIdleDisconnect()
    }

    func failureReason(for error: Error) async -> SSHConnectionFailureReason {
        let message = await (worker ?? retiredDiagnostics)?.collectedDiagnostics() ?? lastStderr
        if !message.isEmpty { return RemoteHostSession.reason(for: SSHProcessFailure(message: message)) }
        if case .failed(let reason) = state { return reason }
        return RemoteHostSession.reason(for: error)
    }

    func disconnect() async {
        cancelIdleDisconnect()
        disconnectedForIdle = false
        let previous = retireCurrentProcess(terminate: true)
        streamGeneration += 1
        transition(to: .disconnected)
        await finishRetirement(previous)
    }

    func send(_ envelope: RPCEnvelope) async throws {
        if !sessionManaged && (disconnectedForIdle || state == .disconnected) {
            try await connect()
        }

        guard let worker else { throw SSHConnectionError.notConnected }
        let generation = streamGeneration
        let frame = try RPCStreamHandler.encodeFrame(envelope.encodedPayload())
        try await worker.perform { try $0.write(frame) }
        guard streamGeneration == generation else { throw RemoteHostSessionError.obsoleteGeneration }
    }

    func setActivePaneCount(_ count: Int) {
        activePaneCount = max(0, count)
        scheduleIdleDisconnectIfNeeded()
    }

    func receive() async throws -> RPCEnvelope {
        guard let worker else { throw SSHConnectionError.notConnected }
        let generation = streamGeneration
        let frame = try await worker.perform { try $0.readFrame(timeout: nil) }
        guard streamGeneration == generation else { throw RemoteHostSessionError.obsoleteGeneration }
        return try RPCEnvelope(encodedPayload: frame)
    }

    func reconnect(afterFailure reason: SSHConnectionFailureReason) async {
        await disconnectAfterFailure(reason)
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

    private func processExited(_ exitedProcess: Process, status: Int32) async {
        guard process === exitedProcess else { return }
        let message = await worker?.collectedDiagnostics() ?? ""
        guard process === exitedProcess else { return }
        cancelIdleDisconnect()
        lastStderr = message
        _ = retireCurrentProcess(terminate: false)

        guard state != .disconnected else { return }
        streamGeneration += 1
        let reason = SSHConnectionFailureReason.processExited(status)
        if sessionManaged {
            let failure = lastStderr.isEmpty ? reason : RemoteHostSession.reason(for: SSHProcessFailure(message: lastStderr))
            transition(to: .failed(reason: failure))
            let callback = sessionFailure
            Task { await callback?(failure) }
            return
        }
        if hasIdleBlockers, SSHReconnectPolicy.isRetryable(reason) {
            Task { [weak self] in
                await self?.reconnect(afterFailure: reason)
            }
            return
        }
        transition(to: .failed(reason: reason))
    }

    private func disconnectAfterFailure(_ reason: SSHConnectionFailureReason) async {
        cancelIdleDisconnect()
        disconnectedForIdle = false
        let previous = retireCurrentProcess(terminate: true)
        streamGeneration += 1
        transition(to: .failed(reason: reason))
        await finishRetirement(previous)
    }

    private func transition(to newState: SSHConnectionState) {
        guard state != newState else { return }
        state = newState
    }

    private var hasIdleBlockers: Bool {
        activePaneCount > 0
    }

    private func scheduleIdleDisconnectIfNeeded() {
        cancelIdleDisconnect()
        guard !sessionManaged, state == .connected, !hasIdleBlockers else { return }

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

    private func disconnectForIdleIfStillInactive() async {
        guard state == .connected, !hasIdleBlockers else { return }
        idleDisconnectTask = nil
        disconnectedForIdle = true
        transition(to: .disconnected)
        let previous = retireCurrentProcess(terminate: true)
        streamGeneration += 1
        await finishRetirement(previous)
    }

    private func retireCurrentProcess(terminate: Bool) -> RemoteProcessWorker? {
        let previous = worker
        let runningProcess = process
        runningProcess?.terminationHandler = nil
        if terminate { previous?.requestStop() }
        retiredDiagnostics = previous
        worker = nil
        process = nil
        ProcessRetirement.retireOnMain(runningProcess)
        return previous
    }

    private func finishRetirement(_ previous: RemoteProcessWorker?) async {
        do { try await previous?.stop() } catch {
            let message = error.localizedDescription
            retirementFailure = message
            transition(to: .failed(reason: .transport(message)))
            Self.logger.error("SSH worker shutdown failed: \(message, privacy: .public)")
        }
    }

    #if DEBUG
    func hasPendingReaderForTesting() -> Bool { worker?.isReading == true }

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

        await disconnectAfterFailure(reason)
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
        guard !sessionManaged else { return }
        Task { @MainActor in
            RemoteConnectionStateStore.shared.setState(newState, for: configuration.hostID, oldState: oldState)
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
}

private struct SSHProcessFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
