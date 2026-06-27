import XCTest
@testable import Detours

final class WindowsTransferChannelTests: XCTestCase {
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

    func testUploadRefusesExistingRemoteTargetWithoutReplace() async throws {
        // Contract: the upload script refuses to overwrite an existing remote target.
        XCTAssertTrue(WindowsTransferChannel.uploadScriptForTesting.contains("Destination already exists"))

        // Behavior: a host-side refusal propagates rather than being silently swallowed.
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let local = try createTestFile(in: temp, name: "u.bin", content: "x")
        let transfer = WindowsTransferChannel(
            powerShellChannel: PowerShellChannel(transport: TransferScriptTransport(responses: [:])),
            sftpClient: FailingWindowsSFTPClient()
        )

        do {
            try await transfer.upload(localURL: local, remotePath: "C:\\dst\\u.bin", byteCount: 1)
            XCTFail("Expected the refusal to propagate")
        } catch {
            // expected: SFTP fails, and the PowerShell fallback's refusal is not swallowed
        }
    }

    func testUploadFallsBackThroughPowerShellWhenSFTPUnavailable() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let local = try createTestFile(in: temp, name: "upload.bin", content: "payload")
        let transport = TransferScriptTransport(responses: [
            "UploadFallback": #"{"BytesWritten":7}"#,
        ])
        let transfer = WindowsTransferChannel(
            powerShellChannel: PowerShellChannel(transport: transport),
            sftpClient: FailingWindowsSFTPClient()
        )

        try await transfer.upload(localURL: local, remotePath: "C:\\Users\\sans\\upload.bin", byteCount: 7)

        let operations = await transport.operations
        XCTAssertEqual(operations, ["UploadFallback"])
    }
}

private actor PartialScriptedSFTP: WindowsSFTPClient {
    private let byteCounts: [Int]
    private var index = 0

    init(byteCounts: [Int]) { self.byteCounts = byteCounts }

    func download(remotePath: String, to localURL: URL) async throws {
        let count = index < byteCounts.count ? byteCounts[index] : 0
        index += 1
        FileManager.default.createFile(atPath: localURL.path, contents: Data(repeating: 0x41, count: count))
    }

    func upload(localURL: URL, remotePath: String) async throws {}
}

private struct FailingWindowsSFTPClient: WindowsSFTPClient {
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

    init(responses: [String: String]) {
        self.responses = responses
    }

    func start(dispatcherBase64: String) async throws {}

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(Request.self, from: payload)
            operations.append(request.operation)
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
