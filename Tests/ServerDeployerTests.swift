import XCTest
@testable import Detours

final class ServerDeployerTests: XCTestCase {
    func testHashCompareSkipsRedeploy() async throws {
        let bundle = try makeBundledBinary()
        defer { cleanupTempDirectory(bundle.deletingLastPathComponent()) }

        let hash = try ServerDeployer.sha256Hex(of: bundle)
        let client = FakeServerDeploymentClient(binaryInfo: .valid, remoteHash: hash)
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        let result = try await deployer.deployIfNeeded()
        let snapshot = await client.snapshot()

        XCTAssertEqual(result, ServerDeploymentResult(deployed: false, reason: .alreadyCurrent))
        XCTAssertFalse(snapshot.didUpload)
        XCTAssertFalse(snapshot.didFinalize)
    }

    func testSilentRedeployOnHashMismatch() async throws {
        let bundle = try makeBundledBinary()
        defer { cleanupTempDirectory(bundle.deletingLastPathComponent()) }

        let client = FakeServerDeploymentClient(binaryInfo: .valid, remoteHash: "old-hash")
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        let result = try await deployer.deployIfNeeded()
        let snapshot = await client.snapshot()

        XCTAssertEqual(result, ServerDeploymentResult(deployed: true, reason: .hashMismatch))
        XCTAssertTrue(snapshot.didUpload)
        XCTAssertTrue(snapshot.didFinalize)
        XCTAssertEqual(snapshot.remoteHash, try ServerDeployer.sha256Hex(of: bundle))
    }

    func testRefusesNonX86_64() async throws {
        let bundle = try makeBundledBinary()
        defer { cleanupTempDirectory(bundle.deletingLastPathComponent()) }

        let client = FakeServerDeploymentClient(
            architecture: RemoteArchitecture(system: "Linux", machine: "aarch64"),
            binaryInfo: nil,
            remoteHash: nil
        )
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        do {
            _ = try await deployer.deployIfNeeded()
            XCTFail("Expected unsupported architecture")
        } catch let error as UnsupportedArchitectureError {
            let snapshot = await client.snapshot()

            XCTAssertEqual(error, UnsupportedArchitectureError(system: "Linux", machine: "aarch64"))
            XCTAssertFalse(snapshot.didUpload)
        }
    }

    func testRefusesWrongOwner() async throws {
        let bundle = try makeBundledBinary()
        defer { cleanupTempDirectory(bundle.deletingLastPathComponent()) }

        let client = FakeServerDeploymentClient(
            binaryInfo: RemoteBinaryInfo(owner: "root", mode: 0o700, isRegularFile: true),
            remoteHash: "old-hash"
        )
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        do {
            _ = try await deployer.deployIfNeeded()
            XCTFail("Expected wrong owner refusal")
        } catch let error as ServerDeployerError {
            let snapshot = await client.snapshot()

            XCTAssertEqual(
                error,
                .insecureInstalledBinary(.wrongOwner(expected: "marco", actual: "root"))
            )
            XCTAssertFalse(snapshot.didUpload)
        }
    }

    func testRefusesGroupOrWorldWritable() async throws {
        let bundle = try makeBundledBinary()
        defer { cleanupTempDirectory(bundle.deletingLastPathComponent()) }

        let client = FakeServerDeploymentClient(
            binaryInfo: RemoteBinaryInfo(owner: "marco", mode: 0o722, isRegularFile: true),
            remoteHash: "old-hash"
        )
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        do {
            _ = try await deployer.deployIfNeeded()
            XCTFail("Expected writable permission refusal")
        } catch let error as ServerDeployerError {
            let snapshot = await client.snapshot()

            XCTAssertEqual(error, .insecureInstalledBinary(.groupOrWorldWritable(mode: 0o722)))
            XCTAssertFalse(snapshot.didUpload)
        }
    }

    func testAtomicRenameDeploy() async throws {
        let bundle = try makeBundledBinary()
        defer { cleanupTempDirectory(bundle.deletingLastPathComponent()) }

        let client = FakeServerDeploymentClient(binaryInfo: nil, remoteHash: nil)
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        let result = try await deployer.deployIfNeeded()
        let snapshot = await client.snapshot()

        XCTAssertEqual(result, ServerDeploymentResult(deployed: true, reason: .missing))
        XCTAssertEqual(
            snapshot.calls,
            [
                "architecture",
                "prepare:~/.detours-server",
                "remove:~/.detours-server/detours-server.tmp",
                "currentUsername",
                "info:~/.detours-server/detours-server",
                "upload:~/.detours-server/detours-server.tmp",
                "finalize:~/.detours-server/detours-server.tmp->~/.detours-server/detours-server",
                "info:~/.detours-server/detours-server",
                "hash:~/.detours-server/detours-server",
            ]
        )
        XCTAssertFalse(snapshot.partialExists)
    }

    func testInterruptedDeployCleansPartialBeforeNextConnect() async throws {
        let bundle = try makeBundledBinary()
        defer { cleanupTempDirectory(bundle.deletingLastPathComponent()) }

        let client = FakeServerDeploymentClient(binaryInfo: nil, remoteHash: nil, failFinalize: true)
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        do {
            _ = try await deployer.deployIfNeeded()
            XCTFail("Expected finalize failure")
        } catch FakeServerDeploymentClient.Failure.finalize {
            let snapshot = await client.snapshot()
            XCTAssertFalse(snapshot.partialExists)
        }

        await client.setFailFinalize(false)
        let result = try await deployer.deployIfNeeded()
        let snapshot = await client.snapshot()

        XCTAssertEqual(result, ServerDeploymentResult(deployed: true, reason: .missing))
        XCTAssertFalse(snapshot.partialExists)
    }

    private func makeBundledBinary(content: String = "detours-server") throws -> URL {
        let temp = try createTempDirectory()
        return try createTestFile(in: temp, name: "detours-server", content: content)
    }
}

private actor FakeServerDeploymentClient: ServerDeploymentClient {
    enum Failure: Error {
        case finalize
    }

    var architecture: RemoteArchitecture
    var username: String
    var binaryInfo: RemoteBinaryInfo?
    var remoteHash: String?
    var failFinalize: Bool
    var partialExists = false
    var didUpload = false
    var didFinalize = false
    var calls: [String] = []

    struct Snapshot {
        let remoteHash: String?
        let partialExists: Bool
        let didUpload: Bool
        let didFinalize: Bool
        let calls: [String]
    }

    init(
        architecture: RemoteArchitecture = RemoteArchitecture(system: "Linux", machine: "x86_64"),
        username: String = "marco",
        binaryInfo: RemoteBinaryInfo?,
        remoteHash: String?,
        failFinalize: Bool = false
    ) {
        self.architecture = architecture
        self.username = username
        self.binaryInfo = binaryInfo
        self.remoteHash = remoteHash
        self.failFinalize = failFinalize
    }

    func architecture() async throws -> RemoteArchitecture {
        calls.append("architecture")
        return architecture
    }

    func currentUsername() async throws -> String {
        calls.append("currentUsername")
        return username
    }

    func installedBinaryInfo(at path: String) async throws -> RemoteBinaryInfo? {
        calls.append("info:\(path)")
        return binaryInfo
    }

    func installedBinaryHash(at path: String) async throws -> String? {
        calls.append("hash:\(path)")
        return remoteHash
    }

    func prepareInstallDirectory(_ path: String) async throws {
        calls.append("prepare:\(path)")
    }

    func removePartialBinary(at path: String) async throws {
        calls.append("remove:\(path)")
        partialExists = false
    }

    func uploadBinary(localFile: URL, remotePath: String) async throws {
        calls.append("upload:\(remotePath)")
        remoteHash = try ServerDeployer.sha256Hex(of: localFile)
        partialExists = true
        didUpload = true
    }

    func finalizeBinary(tempPath: String, finalPath: String) async throws {
        calls.append("finalize:\(tempPath)->\(finalPath)")
        if failFinalize {
            throw Failure.finalize
        }
        partialExists = false
        binaryInfo = .valid
        didFinalize = true
    }

    func setFailFinalize(_ value: Bool) {
        failFinalize = value
    }

    func snapshot() -> Snapshot {
        Snapshot(
            remoteHash: remoteHash,
            partialExists: partialExists,
            didUpload: didUpload,
            didFinalize: didFinalize,
            calls: calls
        )
    }
}

private extension RemoteBinaryInfo {
    static let valid = RemoteBinaryInfo(owner: "marco", mode: 0o700, isRegularFile: true)
}
