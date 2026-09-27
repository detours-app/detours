import XCTest
import RemoteOperationSupport
@testable import Detours

final class WindowsTransferChannelTests: XCTestCase {
    func testMeasuredProgressExpiresWithoutBytesAndAllowsLongTransfers() throws {
        let start = ContinuousClock.now
        let stalled = RemoteMeasuredProgress(startedAt: start)
        stalled.record(0, at: start.advanced(by: .seconds(29)))
        XCTAssertThrowsError(try stalled.check(at: start.advanced(by: .seconds(30))))
        let progressing = RemoteMeasuredProgress(startedAt: start)
        for step in 1...20 {
            let now = start.advanced(by: .seconds(step * 25))
            try progressing.check(at: now)
            progressing.record(UInt64(step), at: now)
        }
        progressing.record(20, at: start.advanced(by: .seconds(525)))
        progressing.record(19, at: start.advanced(by: .seconds(529)))
        XCTAssertThrowsError(try progressing.check(at: start.advanced(by: .seconds(530))))
        let phases = RemoteMeasuredProgress(startedAt: start)
        phases.record(1_000_000, at: start, source: .sent)
        phases.record(1, at: start.advanced(by: .seconds(25)))
        XCTAssertNoThrow(try phases.check(at: start.advanced(by: .seconds(50))))
    }

    func testAcceptedSFTPFailureNeverFallsBack() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let local = try createTestFile(in: temp, name: "upload", content: "payload")
        let (identity, receipt) = acceptedFixture(phase: .preparing)
        let response = try XCTUnwrap(String(bytes: OperationReply.receipt(receipt).encoded(), encoding: .utf8))
        let transport = TransferScriptTransport(responses: ["AcceptedUpload": response])
        let channel = PowerShellChannel(transport: transport)
        let transfer = WindowsTransferChannel(powerShellChannel: channel, sftpClient: FailingWindowsSFTPClient())
        let provider = WindowsRemoteProvider(hostID: UUID(), channel: channel, transferChannel: transfer)
        do {
            _ = try await provider.prepareAcceptedUpload(local, identity: identity, sftpAvailable: true)
            XCTFail("SFTP failure must propagate")
        } catch RemoteTransferError.processFailed(let message) {
            XCTAssertEqual(message, "sftp unavailable")
        }
        let kinds = await transport.requestKinds
        XCTAssertEqual(kinds, ["prepareIngress"])
    }

    func testAcceptedFallbackRequiresUnavailableCapabilityAndHonorsLimit() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let local = try createTestFile(in: temp, name: "upload", content: "payload")
        let (identity, receipt) = acceptedFixture(phase: .readyToCommit)
        let response = try XCTUnwrap(String(bytes: OperationReply.receipt(receipt).encoded(), encoding: .utf8))
        let transport = TransferScriptTransport(responses: ["AcceptedUpload": response])
        let transfer = WindowsTransferChannel(powerShellChannel: PowerShellChannel(transport: transport), sftpClient: FailingWindowsSFTPClient())
        let result = try await transfer.prepareAcceptedUpload(localURL: local, identity: identity, sftpAvailable: false)
        XCTAssertEqual(result, receipt)
        try Data(repeating: 0, count: 1_048_577).write(to: local)
        do {
            _ = try await transfer.prepareAcceptedUpload(localURL: local, identity: identity, sftpAvailable: false)
            XCTFail("Oversized fallback must fail before sending")
        } catch WindowsTransferError.unsupportedLargeTransferWithoutSFTP(let size) {
            XCTAssertEqual(size, 1_048_577)
        }
        let kinds = await transport.requestKinds
        XCTAssertEqual(kinds, ["prepareUpload"])
    }

    func testAcceptedReadyReceiptDoesNotUploadAgain() async throws {
        let (identity, receipt) = acceptedFixture(phase: .readyToCommit)
        let response = try XCTUnwrap(String(bytes: OperationReply.receipt(receipt).encoded(), encoding: .utf8))
        let transport = TransferScriptTransport(responses: ["AcceptedUpload": response])
        let transfer = WindowsTransferChannel(powerShellChannel: PowerShellChannel(transport: transport), sftpClient: FailingWindowsSFTPClient())
        let result = try await transfer.prepareAcceptedUpload(localURL: URL(fileURLWithPath: "/unread"), identity: identity, sftpAvailable: true)
        XCTAssertEqual(result, receipt)
        let kinds = await transport.requestKinds
        XCTAssertEqual(kinds, ["prepareIngress"])
    }

    func testProviderChoosesFallbackOnlyOnUnavailableCapability() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let local = try createTestFile(in: temp, name: "upload", content: "payload")
        let (identity, receipt) = acceptedFixture(phase: .readyToCommit)
        let response = try XCTUnwrap(String(bytes: OperationReply.receipt(receipt).encoded(), encoding: .utf8))
        let transport = TransferScriptTransport(responses: ["AcceptedUpload": response])
        let channel = PowerShellChannel(transport: transport)
        let transfer = WindowsTransferChannel(powerShellChannel: channel, sftpClient: UnavailableWindowsSFTPClient())
        let provider = WindowsRemoteProvider(hostID: UUID(), channel: channel, transferChannel: transfer)

        let result = try await provider.prepareAcceptedUpload(local, identity: identity)

        XCTAssertEqual(result, receipt)
        let kinds = await transport.requestKinds
        XCTAssertEqual(kinds, ["prepareUpload"], "An unavailable host selects the bounded fallback before any payload moves")
    }

    func testProviderUsesIngressWhenSFTPAvailable() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let local = try createTestFile(in: temp, name: "upload", content: "payload")
        let (identity, receipt) = acceptedFixture(phase: .preparing)
        let response = try XCTUnwrap(String(bytes: OperationReply.receipt(receipt).encoded(), encoding: .utf8))
        let transport = TransferScriptTransport(responses: ["AcceptedUpload": response])
        let channel = PowerShellChannel(transport: transport)
        let sftp = RecordingWindowsSFTPClient()
        let transfer = WindowsTransferChannel(powerShellChannel: channel, sftpClient: sftp)
        let provider = WindowsRemoteProvider(hostID: UUID(), channel: channel, transferChannel: transfer)

        _ = try? await provider.prepareAcceptedUpload(local, identity: identity)

        let uploads = await sftp.uploads
        XCTAssertEqual(uploads, 1, "An available host must upload payload through SFTP ingress")
        let kinds = await transport.requestKinds
        XCTAssertEqual(kinds, ["prepareIngress", "sealIngress"])
    }

    private func acceptedFixture(phase: OperationPhase) -> (OperationRequestIdentity, OperationReceipt) {
        let identity = OperationRequestIdentity(id: .init(operation: UUID(), item: UUID()),
            account: .init(hostIdentity: "windows", accountIdentity: "user"), epoch: UUID(), intentDigest: "intent")
        let payload = OperationEffect(location: .init(account: identity.account, path: .windows(#"C:\owned\ingress"#)),
            observation: .init(identity: .init(volume: Data([1]), object: Data([2])), kind: .file,
                version: Data([3]), byteCount: 0, sha256: nil, linkTarget: nil))
        let receipt = OperationReceipt(id: identity.id, account: identity.account, epoch: identity.epoch,
            intentDigest: identity.intentDigest, revision: 1, phase: phase, outcome: .running, preparedPayload: payload)
        return (identity, receipt)
    }

    func testSFTPPathUsesWindowsOpenSSHDriveRoot() {
        XCTAssertEqual(
            ProcessWindowsSFTPClient.sftpPath(fromNativePath: #"C:\Users\sans\file.txt"#),
            "/C:/Users/sans/file.txt"
        )
    }

    func testSFTPUnavailableFallbackThreshold() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let thresholdPayload = Data(repeating: 7, count: Int(RemoteTransferChannel.rpcThresholdBytes))
        let transport = TransferScriptTransport(responses: [
            "DownloadFallback": try JSONEncoder.detoursWindows.encodeString(thresholdPayload.base64EncodedString()),
        ])
        let channel = PowerShellChannel(transport: transport)
        let transfer = WindowsTransferChannel(
            powerShellChannel: channel,
            sftpClient: FailingWindowsSFTPClient()
        )
        let destination = temp.appendingPathComponent("fallback.bin")

        try await transfer.download(
            remotePath: "C:\\Users\\sans\\fallback.bin",
            expectedByteCount: RemoteTransferChannel.rpcThresholdBytes,
            to: destination
        )

        XCTAssertEqual(try Data(contentsOf: destination), thresholdPayload)

        do {
            try await transfer.download(
                remotePath: "C:\\Users\\sans\\large.bin",
                expectedByteCount: RemoteTransferChannel.rpcThresholdBytes + 1,
                to: temp.appendingPathComponent("large.bin")
            )
            XCTFail("Expected large transfer without SFTP to fail")
        } catch WindowsTransferError.unsupportedLargeTransferWithoutSFTP(let byteCount) {
            XCTAssertEqual(byteCount, RemoteTransferChannel.rpcThresholdBytes + 1)
        }
    }

    func testDownloadUsesPartialTempAndCleansUpOnFailure() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = temp.appendingPathComponent("file.bin")
        let partial = RemoteTransferChannel.partialURL(for: destination)
        // First SFTP attempt is truncated (2 of 4 bytes), the retry is complete.
        let sftp = PartialScriptedSFTP(byteCounts: [2, 4])
        // Threshold 0 keeps a failed download from falling through to the PowerShell path,
        // so the partial-file cleanup is observable directly.
        let transfer = WindowsTransferChannel(
            powerShellChannel: PowerShellChannel(transport: TransferScriptTransport(responses: [:])),
            sftpClient: sftp,
            fallbackThreshold: 0
        )

        // Interrupted/size-mismatched download leaves no corrupt file at the destination.
        do {
            try await transfer.download(remotePath: "C:\\f.bin", expectedByteCount: 4, to: destination)
            XCTFail("Expected the truncated download to fail")
        } catch {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "partial must be cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no corrupt file at destination")

        // A retry to the same destination then succeeds.
        try await transfer.download(remotePath: "C:\\f.bin", expectedByteCount: 4, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination).count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testLegacyUploadNeverStartsSFTPOrFallback() async throws {
        let transport = TransferScriptTransport(responses: [:])
        let sftp = RecordingWindowsSFTPClient()
        let transfer = WindowsTransferChannel(powerShellChannel: PowerShellChannel(transport: transport), sftpClient: sftp)
        do {
            try await transfer.upload(localURL: URL(fileURLWithPath: "/must-not-read"), remotePath: "C:\\target", byteCount: 7)
            XCTFail("Legacy upload was accepted")
        } catch let error as WindowsTransferError { XCTAssertEqual(error, .acceptedOperationRequired) }
        let operations = await transport.operations
        let uploads = await sftp.uploads
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(uploads, 0)
    }

}

private actor PartialScriptedSFTP: WindowsSFTPClient {
    private let byteCounts: [Int]
    private var index = 0

    init(byteCounts: [Int]) { self.byteCounts = byteCounts }

    func isAvailable() async -> Bool { true }

    func download(remotePath: String, to localURL: URL) async throws {
        let count = index < byteCounts.count ? byteCounts[index] : 0
        index += 1
        FileManager.default.createFile(atPath: localURL.path, contents: Data(repeating: 0x41, count: count))
    }

    func upload(localURL: URL, remotePath: String) async throws {}
}

private struct FailingWindowsSFTPClient: WindowsSFTPClient {
    func isAvailable() async -> Bool { false }

    func download(remotePath: String, to localURL: URL) async throws {
        throw RemoteTransferError.processFailed("sftp unavailable")
    }

    func upload(localURL: URL, remotePath: String) async throws {
        throw RemoteTransferError.processFailed("sftp unavailable")
    }
}

private struct UnavailableWindowsSFTPClient: WindowsSFTPClient {
    func isAvailable() async -> Bool { false }

    func download(remotePath: String, to localURL: URL) async throws {
        throw RemoteTransferError.processFailed("sftp unavailable")
    }

    func upload(localURL: URL, remotePath: String) async throws {
        throw RemoteTransferError.processFailed("sftp unavailable")
    }
}

private actor TransferScriptTransport: PowerShellChannelTransport {
    private struct Request: Decodable {
        let id: UInt64
        let operation: String
        let argumentsJSON: String
    }

    private struct Response: Encodable {
        let id: UInt64
        let ok: Bool
        let resultJSON: String?
        let error: String?
    }

    private var handler = RPCStreamHandler()
    private let responses: [String: String]
    private var queued: [Data] = []
    private(set) var operations: [String] = []
    private(set) var requestKinds: [String] = []

    init(responses: [String: String]) {
        self.responses = responses
    }

    func start(dispatcherBase64: String) async throws {}

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(Request.self, from: payload)
            operations.append(request.operation)
            let arguments = try JSONSerialization.jsonObject(with: Data(request.argumentsJSON.utf8)) as? [String: Any]
            if let operation = arguments?["request"] as? [String: Any] { requestKinds.append(contentsOf: operation.keys.sorted()) }
            let response = Response(
                id: request.id,
                ok: responses[request.operation] != nil,
                resultJSON: responses[request.operation],
                error: responses[request.operation] == nil ? "No scripted response" : nil
            )
            queued.append(try JSONEncoder.detoursWindows.encode(response))
        }
    }

    func readFrame() async throws -> Data {
        guard !queued.isEmpty else {
            throw PowerShellChannelError.invalidResponse("No scripted response.")
        }
        return queued.removeFirst()
    }

    func stop() async {}
}

private extension JSONEncoder {
    func encodeString(_ value: String) throws -> String {
        let data = try encode(value)
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }
}

private actor RecordingWindowsSFTPClient: WindowsSFTPClient {
    private(set) var uploads = 0
    func isAvailable() async -> Bool { true }
    func download(remotePath: String, to localURL: URL) async throws {}
    func upload(localURL: URL, remotePath: String) async throws { uploads += 1 }
}
