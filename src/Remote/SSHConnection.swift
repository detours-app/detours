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

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var frameReader = RPCStreamHandler()

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
        processFactory: @escaping @Sendable () -> Process = { Process() }
    ) {
        self.configuration = configuration
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.askPassBridge = askPassBridge
        self.processFactory = processFactory
    }

    func connect() async throws {
        guard process == nil else { return }

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
    }

    func disconnect() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        frameReader = RPCStreamHandler()
        transition(to: .disconnected)
    }

    func send(_ envelope: RPCEnvelope) async throws {
        guard let stdinPipe else {
            throw SSHConnectionError.notConnected
        }

        let frame = try RPCStreamHandler.encodeFrame(envelope.encodedPayload())
        stdinPipe.fileHandleForWriting.write(frame)
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

        var elapsed: TimeInterval = 0
        var attempt = 1

        while SSHReconnectPolicy.shouldContinue(afterElapsed: elapsed),
              let delay = SSHReconnectPolicy.delay(forAttempt: attempt) {
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
        process = nil
        stdinPipe = nil
        stdoutPipe = nil

        guard state != .disconnected else { return }
        transition(to: .failed(reason: .processExited(status)))
    }

    private func disconnectAfterFailure(_ reason: SSHConnectionFailureReason) {
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
