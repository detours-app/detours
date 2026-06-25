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
