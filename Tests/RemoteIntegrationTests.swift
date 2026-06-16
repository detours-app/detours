import XCTest
@testable import Detours

final class RemoteIntegrationTests: XCTestCase {
    func testListDirectoryReturnsExpectedEntries() async throws {
        let session = try RemoteIntegrationSession.make()

        let started = Date()
        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: "/etc"), showHidden: false)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
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

    func testLargeTransferUsesRemoteTransferChannel() async throws {
        let session = try RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("dd if=/dev/zero of=\(Self.shellQuote(remoteRoot + "/large.bin")) bs=1M count=100 status=none")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = localRoot.appendingPathComponent("large.bin")

        let download = Task {
            try await session.provider.download(.remote(hostID: session.hostID, path: remoteRoot + "/large.bin"), to: destination)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: "/etc"), showHidden: false)

        try await download.value
        let size = try XCTUnwrap(destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(size, 100 * 1_024 * 1_024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RemoteTransferChannel.partialURL(for: destination).path))
        XCTAssertTrue(entries.contains { $0.name == "hosts" })
    }

    func testWatchDirectoryReceivesInotifyEvent() async throws {
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        let session = try PersistentRemoteRPCSession.start()
        defer { session.close() }
        let token = UUID()

        try session.send(.watch(path: RemotePath(remoteRoot), token: token), id: 1)
        _ = try session.waitForEnvelope(timeout: 2) { envelope in
            envelope.id == 1 && envelope.kind == .response
        }

        try Self.runSSH("printf watched > \(Self.shellQuote(remoteRoot + "/watched.txt"))")
        let envelope = try session.waitForEnvelope(timeout: 2) { envelope in
            envelope.kind == .event && envelope.messageType == "WatchEvent"
        }
        let message = try RPCMessage(binaryEncoded: envelope.payload)

        guard case .watchEvent(let watch, _, let path) = message else {
            XCTFail("Expected WatchEvent")
            return
        }
        XCTAssertEqual(watch, token)
        XCTAssertEqual(path, RemotePath(remoteRoot + "/watched.txt"))
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

    func testReconnectAfterIdle() async throws {
        try Self.runSSH("test -x ~/.detours-server/detours-server")
        let hostID = UUID()
        let controlRoot = URL(fileURLWithPath: "/tmp").appendingPathComponent("dtssh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let controlDirectory = controlRoot.appendingPathComponent("ssh", isDirectory: true)
        defer { cleanupTempDirectory(controlRoot) }
        let userKnownHosts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: hostID, sshTarget: "devtest"),
            controlDirectory: controlDirectory,
            hostTrust: SSHHostTrust(knownHostsURL: userKnownHosts),
            idleTimeout: 0.05
        )
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: SSHRemoteRPCClient(connection: connection),
            transferChannel: RemoteTransferChannel(sshTarget: "devtest", controlDirectory: controlDirectory)
        )

        try await connection.connect()
        await connection.setActivePaneCount(0)
        try await Task.sleep(nanoseconds: 150_000_000)
        let disconnectedForIdle = await connection.isDisconnectedForIdleForTesting()
        await connection.setActivePaneCount(1)
        let entries: [LoadedFileEntry]
        do {
            entries = try await provider.list(.remote(hostID: hostID, path: "/etc"), showHidden: false)
        } catch {
            let state = await connection.state
            let idle = await connection.isDisconnectedForIdleForTesting()
            let stderr = await connection.lastStderrForTesting()
            XCTFail("list after idle failed with \(error), state: \(state), disconnectedForIdle: \(idle), stderr: \(stderr)")
            await connection.disconnect()
            return
        }
        await connection.disconnect()

        XCTAssertTrue(disconnectedForIdle)
        XCTAssertTrue(entries.contains { $0.name == "hosts" })
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

    func testIntelMacListDirectoryReturnsExpectedEntries() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let home = try Self.remoteHome(target: "wraith")

        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: home), showHidden: false)

        XCTAssertFalse(entries.isEmpty)
    }

    func testIntelMacPersistentSSHConnectionListsHome() async throws {
        try await RemoteIntegrationSession.deployIntelMacHelper()
        let temp = URL(fileURLWithPath: "/tmp").appendingPathComponent("dtssh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { cleanupTempDirectory(temp) }
        let hostID = UUID()
        let knownHostsURL = temp.appendingPathComponent("known_hosts")
        let controlDirectory = temp.appendingPathComponent("ssh", isDirectory: true)
        let trust = SSHHostTrust(knownHostsURL: knownHostsURL)
        let hostKey = try await trust.scanHostKey(for: "wraith")
        try trust.recordTrustedHostKey(hostKey, hostID: hostID)
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: hostID, sshTarget: "wraith"),
            controlDirectory: controlDirectory,
            hostTrust: trust
        )
        let rpcClient = SSHRemoteRPCClient(connection: connection)
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: rpcClient,
            transferChannel: RemoteTransferChannel(sshTarget: "wraith", controlDirectory: controlDirectory)
        )
        let home = try Self.remoteHome(target: "wraith")

        try await connection.connect()
        let response: [Data]
        let entries: [LoadedFileEntry]
        do {
            response = try await rpcClient.send(.protocolVersion(1))
            entries = try await provider.list(.remote(hostID: hostID, path: home), showHidden: false)
        } catch {
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()

        XCTAssertEqual(response.count, 1)
        XCTAssertFalse(entries.isEmpty)
    }

    func testIntelMacCopyRemoteToLocal() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: "wraith")
        defer { Self.cleanupRemote(remoteRoot, target: "wraith") }
        try Self.runSSH("printf remote-body > \(Self.shellQuote(remoteRoot + "/remote.txt"))", target: "wraith")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = localRoot.appendingPathComponent("remote.txt")

        try await session.provider.download(.remote(hostID: session.hostID, path: remoteRoot + "/remote.txt"), to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "remote-body")
    }

    func testIntelMacCopyLocalToRemote() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: "wraith")
        defer { Self.cleanupRemote(remoteRoot, target: "wraith") }
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let source = try createTestFile(in: localRoot, name: "upload.txt", content: "local-body")

        try await session.provider.upload(source, to: .remote(hostID: session.hostID, path: remoteRoot + "/upload.txt"))
        let entry = try await session.provider.stat(.remote(hostID: session.hostID, path: remoteRoot + "/upload.txt"))

        XCTAssertEqual(entry.fileSize, 10)
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(remoteRoot + "/upload.txt"))", target: "wraith"), "local-body")
    }

    func testIntelMacLargeTransferUsesRemoteTransferChannel() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: "wraith")
        defer { Self.cleanupRemote(remoteRoot, target: "wraith") }
        try Self.runSSH("dd if=/dev/zero of=\(Self.shellQuote(remoteRoot + "/large.bin")) bs=1m count=100 2>/dev/null", target: "wraith")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = localRoot.appendingPathComponent("large.bin")
        let home = try Self.remoteHome(target: "wraith")

        let download = Task {
            try await session.provider.download(.remote(hostID: session.hostID, path: remoteRoot + "/large.bin"), to: destination)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: home), showHidden: false)

        try await download.value
        let size = try XCTUnwrap(destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(size, 100 * 1_024 * 1_024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RemoteTransferChannel.partialURL(for: destination).path))
        XCTAssertFalse(entries.isEmpty)
    }

    func testIntelMacWatchDirectoryReceivesDarwinEvent() async throws {
        _ = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: "wraith")
        defer { Self.cleanupRemote(remoteRoot, target: "wraith") }
        let session = try PersistentRemoteRPCSession.start(sshTarget: "wraith")
        defer { session.close() }
        let token = UUID()

        try session.send(.watch(path: RemotePath(remoteRoot), token: token), id: 1)
        _ = try session.waitForEnvelope(timeout: 2) { envelope in
            envelope.id == 1 && envelope.kind == .response
        }

        try Self.runSSH("printf watched > \(Self.shellQuote(remoteRoot + "/watched.txt"))", target: "wraith")
        let envelope = try session.waitForEnvelope(timeout: 2) { envelope in
            envelope.kind == .event && envelope.messageType == "WatchEvent"
        }
        let message = try RPCMessage(binaryEncoded: envelope.payload)

        guard case .watchEvent(let watch, _, _) = message else {
            XCTFail("Expected WatchEvent")
            return
        }
        XCTAssertEqual(watch, token)
    }

    func testIntelMacTrashAndRestore() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: "wraith")
        defer { Self.cleanupRemote(remoteRoot, target: "wraith") }
        try Self.runSSH("printf trash > \(Self.shellQuote(remoteRoot + "/trash.txt"))", target: "wraith")
        let location = Location.remote(hostID: session.hostID, path: remoteRoot + "/trash.txt")

        let trashed = try await session.provider.trash([location])
        XCTAssertFalse(try Self.remotePathExists(remoteRoot + "/trash.txt", target: "wraith"))
        let restored = try await session.provider.restoreFromTrash(trashed)

        XCTAssertEqual(restored, [location])
        XCTAssertTrue(try Self.remotePathExists(remoteRoot + "/trash.txt", target: "wraith"))
    }

    func testIntelMacUnsupportedArmFixture() async throws {
        let bundleRoot = try createTempDirectory()
        defer { cleanupTempDirectory(bundleRoot) }
        let bundle = try createTestFile(in: bundleRoot, name: "detours-server", content: "server")
        let client = IntegrationDeploymentClient(
            architecture: RemoteArchitecture(system: "Darwin", machine: "arm64")
        )
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        do {
            _ = try await deployer.deployIfNeeded()
            XCTFail("Expected unsupported architecture")
        } catch let error as UnsupportedArchitectureError {
            XCTAssertEqual(error, UnsupportedArchitectureError(system: "Darwin", machine: "arm64"))
            XCTAssertTrue(error.localizedDescription.contains("x86_64 macOS"))
            let didUpload = await client.didUpload
            XCTAssertFalse(didUpload)
        }
    }

    func testSymlinkBrokenShowsError() {
        let message = FileListViewController.remoteBrokenSymlinkMessage(fileName: "missing-link")

        XCTAssertEqual(message, "Remote symbolic link \"missing-link\" is broken or unreachable")
    }

    private static func makeRemoteFixtureRoot() throws -> String {
        try makeRemoteFixtureRoot(target: "devtest")
    }

    private static func makeRemoteFixtureRoot(target: String) throws -> String {
        let root = try runSSH("printf %s \"$HOME/.detours-test/\(UUID().uuidString)\"", target: target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runSSH("mkdir -p \(shellQuote(root))", target: target)
        return root
    }

    private static func cleanupRemote(_ path: String) {
        cleanupRemote(path, target: "devtest")
    }

    private static func cleanupRemote(_ path: String, target: String) {
        _ = try? runSSH("rm -rf \(shellQuote(path))", target: target)
    }

    private static func remotePathExists(_ path: String, target: String = "devtest") throws -> Bool {
        let process = try configuredSSHProcess(command: "test -e \(shellQuote(path))", target: target)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard process.waitUntilExit(timeout: 5) else {
            process.terminate()
            throw XCTSkip("\(target) timed out")
        }
        return process.terminationStatus == 0
    }

    @discardableResult
    fileprivate static func runSSH(_ command: String, target: String = "devtest") throws -> String {
        let process = try configuredSSHProcess(command: command, target: target)
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        guard process.waitUntilExit(timeout: 15) else {
            process.terminate()
            throw XCTSkip("\(target) timed out")
        }
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(target) unavailable: \(stderr)")
        }
        return stdout
    }

    fileprivate static func configuredSSHProcess(command: String, target: String = "devtest") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            target,
            command,
        ]
        return process
    }

    fileprivate static func prepareDefaultSSHControlDirectory() throws {
        let controlDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory.path)
    }

    fileprivate static func requireIntelMacHost(_ target: String) throws {
        let architecture = try runSSH("uname -sm", target: target).trimmingCharacters(in: .whitespacesAndNewlines)
        guard architecture == "Darwin x86_64" else {
            throw XCTSkip("\(target) reported \(architecture), expected Darwin x86_64")
        }
    }

    fileprivate static func remoteHome(target: String) throws -> String {
        try runSSH("printf %s \"$HOME\"", target: target).trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct ProcessRemoteRPCClient: RemoteRPCClient {
    let sshTarget: String

    init(sshTarget: String = "devtest") {
        self.sshTarget = sshTarget
    }

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
            sshTarget,
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
            throw RemoteFileProviderError.invalidResponse("\(sshTarget) RPC timed out")
        }
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RemoteFileProviderError.invalidResponse("\(sshTarget) RPC failed: \(stderrText)")
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

private final class PersistentRemoteRPCSession: @unchecked Sendable {
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

private extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        terminationHandler = { _ in semaphore.signal() }
        if !isRunning { return true }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
