import XCTest
@testable import Detours

final class RemoteIntegrationTests: XCTestCase {
    func testListDirectoryReturnsExpectedEntries() async throws {
        let session = try RemoteIntegrationSession.make()

        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: "/etc"), showHidden: false)

        XCTAssertTrue(entries.contains { $0.name == "hosts" })
    }

    func testCopyRemoteToLocal() async throws {
        let session = try RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf remote-body > \(Self.shellQuote(remoteRoot + "/remote.txt"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = localRoot.appendingPathComponent("remote.txt")

        try await session.provider.download(.remote(hostID: session.hostID, path: remoteRoot + "/remote.txt"), to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "remote-body")
    }

    func testCopyLocalToRemote() async throws {
        let session = try RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let source = try createTestFile(in: localRoot, name: "upload.txt", content: "local-body")

        try await session.provider.upload(source, to: .remote(hostID: session.hostID, path: remoteRoot + "/upload.txt"))
        let entry = try await session.provider.stat(.remote(hostID: session.hostID, path: remoteRoot + "/upload.txt"))

        XCTAssertEqual(entry.fileSize, 10)
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(remoteRoot + "/upload.txt"))"), "local-body")
    }

    func testTrashAndRestore() async throws {
        let session = try RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf trash > \(Self.shellQuote(remoteRoot + "/trash.txt"))")
        let location = Location.remote(hostID: session.hostID, path: remoteRoot + "/trash.txt")

        let trashed = try await session.provider.trash([location])
        XCTAssertFalse(try Self.remotePathExists(remoteRoot + "/trash.txt"))
        let restored = try await session.provider.restoreFromTrash(trashed)

        XCTAssertEqual(restored, [location])
        XCTAssertTrue(try Self.remotePathExists(remoteRoot + "/trash.txt"))
    }

    func testGitStatusOverlay() async throws {
        let session = try RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH(
            """
            cd \(Self.shellQuote(remoteRoot)); \
            git init >/dev/null; \
            git config user.email detours@example.test; \
            git config user.name 'Detours Tests'; \
            printf one > tracked.txt; \
            git add tracked.txt; \
            git commit -m initial >/dev/null; \
            printf two > tracked.txt
            """
        )

        let statuses = await session.provider.gitStatus(for: .remote(hostID: session.hostID, path: remoteRoot))

        XCTAssertEqual(statuses[.remote(hostID: session.hostID, path: remoteRoot + "/tracked.txt")], .modified)
    }

    func testSymlinkFollowsResolvable() async throws {
        let session = try RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("mkdir -p \(Self.shellQuote(remoteRoot + "/target")); ln -s target \(Self.shellQuote(remoteRoot + "/link"))")

        let target = try await session.provider.readSymlink(.remote(hostID: session.hostID, path: remoteRoot + "/link"))

        XCTAssertEqual(target, .remote(hostID: session.hostID, path: remoteRoot + "/target"))
    }

    func testPermissionDeniedRendersLockBadge() async throws {
        let session = try RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer {
            _ = try? Self.runSSH("chmod -R u+rwX \(Self.shellQuote(remoteRoot))")
            Self.cleanupRemote(remoteRoot)
        }
        try Self.runSSH("printf secret > \(Self.shellQuote(remoteRoot + "/secret.txt")); chmod 000 \(Self.shellQuote(remoteRoot + "/secret.txt"))")

        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: remoteRoot), showHidden: false)

        let secret = try XCTUnwrap(entries.first { $0.name == "secret.txt" })
        XCTAssertFalse(secret.isReadable)
    }

    @MainActor
    func testHostKeyChangeBlocks() throws {
        let defaults = try Self.makeDefaults()
        let store = RemoteHostStore(defaults: defaults)
        let host = store.add(displayName: "Dev VM", sshTarget: "devtest")
        store.updateFingerprint(id: host.id, fingerprint: "SHA256:old")

        let evaluation = SSHHostTrust().evaluateFingerprint("SHA256:new", for: host.id, in: store)

        XCTAssertEqual(evaluation, .changed(old: "SHA256:old", new: "SHA256:new"))
        XCTAssertEqual(store.host(id: host.id)?.knownHostKeyFingerprint, "SHA256:old")
    }

    func testUnsupportedArchitectureError() async throws {
        let bundleRoot = try createTempDirectory()
        defer { cleanupTempDirectory(bundleRoot) }
        let bundle = try createTestFile(in: bundleRoot, name: "detours-server", content: "server")
        let client = IntegrationDeploymentClient(
            architecture: RemoteArchitecture(system: "Linux", machine: "aarch64")
        )
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        do {
            _ = try await deployer.deployIfNeeded()
            XCTFail("Expected unsupported architecture")
        } catch let error as UnsupportedArchitectureError {
            XCTAssertEqual(error, UnsupportedArchitectureError(system: "Linux", machine: "aarch64"))
            let didUpload = await client.didUpload
            XCTAssertFalse(didUpload)
        }
    }

    func testSymlinkBrokenShowsError() {
        let message = FileListViewController.remoteBrokenSymlinkMessage(fileName: "missing-link")

        XCTAssertEqual(message, "Remote symbolic link \"missing-link\" is broken or unreachable")
    }

    private static func makeRemoteFixtureRoot() throws -> String {
        let root = try runSSH("printf %s \"$HOME/.detours-test/\(UUID().uuidString)\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runSSH("mkdir -p \(shellQuote(root))")
        return root
    }

    private static func cleanupRemote(_ path: String) {
        _ = try? runSSH("rm -rf \(shellQuote(path))")
    }

    private static func remotePathExists(_ path: String) throws -> Bool {
        let process = try configuredSSHProcess(command: "test -e \(shellQuote(path))")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard process.waitUntilExit(timeout: 5) else {
            process.terminate()
            throw XCTSkip("devtest timed out")
        }
        return process.terminationStatus == 0
    }

    @discardableResult
    fileprivate static func runSSH(_ command: String) throws -> String {
        let process = try configuredSSHProcess(command: command)
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        guard process.waitUntilExit(timeout: 15) else {
            process.terminate()
            throw XCTSkip("devtest timed out")
        }
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw XCTSkip("devtest unavailable: \(stderr)")
        }
        return stdout
    }

    fileprivate static func configuredSSHProcess(command: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "devtest", command]
        return process
    }

    fileprivate static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func makeDefaults() throws -> UserDefaults {
        let suiteName = "RemoteIntegrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private struct RemoteIntegrationSession {
    let hostID: UUID
    let provider: RemoteFileProvider

    static func make() throws -> RemoteIntegrationSession {
        try RemoteIntegrationTests.runSSH("test -x ~/.detours-server/detours-server")
        let hostID = UUID()
        let client = ProcessRemoteRPCClient()
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )
        return RemoteIntegrationSession(hostID: hostID, provider: provider)
    }
}

private struct ProcessRemoteRPCClient: RemoteRPCClient {
    func send(_ message: RPCMessage) async throws -> [Data] {
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
            "devtest",
            "~/.detours-server/detours-server",
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let request = RPCEnvelope(
            id: 1,
            kind: .request,
            messageType: message.messageType,
            sequence: 0,
            isFinal: true,
            payload: try message.binaryEncoded()
        )
        let frame = try RPCStreamHandler.encodeFrame(request.encodedPayload())
        stdin.fileHandleForWriting.write(frame)
        try stdin.fileHandleForWriting.close()

        guard process.waitUntilExit(timeout: 15) else {
            process.terminate()
            throw RemoteFileProviderError.invalidResponse("devtest RPC timed out")
        }
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RemoteFileProviderError.invalidResponse("devtest RPC failed: \(stderrText)")
        }

        var stream = RPCStreamHandler()
        let frames = try stream.append(stdout.fileHandleForReading.readDataToEndOfFile())
        let decoded = try frames.map { frame in
            try RPCEnvelope(encodedPayload: frame)
        }
        let responses = decoded.filter { envelope in
            envelope.id == 1 && envelope.kind == .response
        }
        let envelopes = responses.sorted { lhs, rhs in
            lhs.sequence < rhs.sequence
        }
        guard envelopes.last?.isFinal == true else {
            throw RemoteFileProviderError.invalidResponse("devtest RPC missing final frame")
        }
        return envelopes.map { $0.payload }
    }
}

private actor IntegrationDeploymentClient: ServerDeploymentClient {
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

private extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        terminationHandler = { _ in semaphore.signal() }
        if !isRunning { return true }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
