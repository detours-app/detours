import XCTest
@testable import Detours

struct RemoteIntegrationSession {
    let hostID: UUID
    let provider: RemoteFileProvider

    static func make() throws -> RemoteIntegrationSession {
        try RemoteIntegrationTests.runSSH("test -x ~/.detours-server/detours-server")
        return try make(sshTarget: "devtest")
    }

    static func make(sshTarget: String) throws -> RemoteIntegrationSession {
        try RemoteIntegrationTests.prepareDefaultSSHControlDirectory()
        let hostID = UUID()
        let client = ProcessRemoteRPCClient(sshTarget: sshTarget)
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: sshTarget)
        )
        return RemoteIntegrationSession(hostID: hostID, provider: provider)
    }

    static func makeIntelMac() async throws -> RemoteIntegrationSession {
        try await deployIntelMacHelper()
        return try make(sshTarget: "wraith")
    }

    static func deployIntelMacHelper() async throws {
        try RemoteIntegrationTests.requireIntelMacHost("wraith")
        let deployer = ServerDeployer(
            client: SSHServerDeploymentClient(sshTarget: "wraith"),
            bundledBinaryDirectoryURL: URL(fileURLWithPath: "resources/Servers")
        )
        _ = try await deployer.deployIfNeeded()
    }
}

actor IntegrationDeploymentClient: ServerDeploymentClient {
    let architecture: RemoteArchitecture
    var didUpload = false

    init(architecture: RemoteArchitecture) {
        self.architecture = architecture
    }

    func architecture() async throws -> RemoteArchitecture {
        architecture
    }

    func currentUsername() async throws -> String {
        "maf"
    }

    func installedBinaryInfo(at path: String) async throws -> RemoteBinaryInfo? {
        nil
    }

    func installedBinaryHash(at path: String) async throws -> String? {
        nil
    }

    func prepareInstallDirectory(_ path: String) async throws {}

    func removePartialBinary(at path: String) async throws {}

    func uploadBinary(localFile: URL, remotePath: String) async throws {
        didUpload = true
    }

    func finalizeBinary(tempPath: String, finalPath: String) async throws {}
}

/// Exercises ServerDeployer's failure cleanup through real SSH and scp. Only the final
/// destination is redirected to a path that cannot be written; every transport operation is
/// performed by SSHServerDeploymentClient against the Foundry `devtest` fixture.
struct FailingFinalizationSSHDeploymentClient: ServerDeploymentClient {
    let base: SSHServerDeploymentClient

    func architecture() async throws -> RemoteArchitecture { try await base.architecture() }
    func currentUsername() async throws -> String { try await base.currentUsername() }
    func installedBinaryInfo(at path: String) async throws -> RemoteBinaryInfo? {
        try await base.installedBinaryInfo(at: path)
    }
    func installedBinaryHash(at path: String) async throws -> String? {
        try await base.installedBinaryHash(at: path)
    }
    func prepareInstallDirectory(_ path: String) async throws { try await base.prepareInstallDirectory(path) }
    func removePartialBinary(at path: String) async throws { try await base.removePartialBinary(at: path) }
    func uploadBinary(localFile: URL, remotePath: String) async throws {
        try await base.uploadBinary(localFile: localFile, remotePath: remotePath)
    }
    func finalizeBinary(tempPath: String, finalPath: String) async throws {
        try await base.finalizeBinary(
            tempPath: tempPath,
            finalPath: "/proc/detours-tests-\(UUID().uuidString)"
        )
    }
}

final class PersistentRemoteRPCSession: @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private let queue = DispatchQueue(label: "PersistentRemoteRPCSession")
    private var envelopes: [RPCEnvelope] = []

    private init(process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    static func start(sshTarget: String = "devtest") throws -> PersistentRemoteRPCSession {
        try RemoteIntegrationTests.prepareDefaultSSHControlDirectory()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(FileManager.default.homeDirectoryForCurrentUser.path)/.detours/ssh/%C",
            "-o", "UserKnownHostsFile=\(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh/known_hosts",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PubkeyAuthentication=yes",
            "-o", "NumberOfPasswordPrompts=0",
            sshTarget,
            "~/.detours-server/detours-server",
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let session = PersistentRemoteRPCSession(process: process, stdin: stdin, stdout: stdout, stderr: stderr)
        try process.run()
        return session
    }

    func send(_ message: RPCMessage, id: UInt64) throws {
        let request = RPCEnvelope(
            id: id,
            kind: .request,
            messageType: message.messageType,
            sequence: 0,
            isFinal: true,
            payload: try message.binaryEncoded()
        )
        stdin.fileHandleForWriting.write(try RPCStreamHandler.encodeFrame(request.encodedPayload()))
    }

    func waitForEnvelope(timeout: TimeInterval, matching predicate: (RPCEnvelope) -> Bool) throws -> RPCEnvelope {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let envelope = popBufferedEnvelope(matching: predicate) {
                return envelope
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let semaphore = DispatchSemaphore(value: 0)
            final class ResultBox: @unchecked Sendable {
                var result: Result<RPCEnvelope, Error>?
            }
            let box = ResultBox()
            DispatchQueue.global(qos: .utility).async {
                box.result = Result { try self.readNextEnvelope() }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + remaining) != .success {
                break
            }
            let envelope = try box.result!.get()
            if predicate(envelope) {
                return envelope
            }
            buffer(envelope)
        }
        throw RemoteFileProviderError.invalidResponse("Timed out waiting for RPC envelope")
    }

    func close() {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func readNextEnvelope() throws -> RPCEnvelope {
        let lengthBytes = stdout.fileHandleForReading.readData(ofLength: 4)
        guard lengthBytes.count == 4 else {
            throw RemoteFileProviderError.invalidResponse("RPC stream closed")
        }
        let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let payload = stdout.fileHandleForReading.readData(ofLength: length)
        guard payload.count == length else {
            throw RemoteFileProviderError.invalidResponse("RPC frame truncated")
        }
        return try RPCEnvelope(encodedPayload: payload)
    }

    private func popBufferedEnvelope(matching predicate: (RPCEnvelope) -> Bool) -> RPCEnvelope? {
        queue.sync {
            guard let index = envelopes.firstIndex(where: predicate) else { return nil }
            return envelopes.remove(at: index)
        }
    }

    private func buffer(_ envelope: RPCEnvelope) {
        queue.sync {
            envelopes.append(envelope)
        }
    }
}
