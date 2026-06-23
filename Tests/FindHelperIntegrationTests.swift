import XCTest
@testable import Detours

/// Drives the actual compiled `detours-server` helper binary over the framed RPC protocol and
/// confirms a `find` request returns matches. This exercises the whole find path end to end
/// (client message encode -> wire frame -> helper RPC dispatch -> FindOperations traversal ->
/// result-chunk decode) against the real binary, not just the unit-level pieces.
final class FindHelperIntegrationTests: XCTestCase {
    func testFindReturnsMatchesFromRealHelperBinary() throws {
        let helper = URL(fileURLWithPath: "resources/Servers/detours-server-x86_64-darwin")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: helper.path),
            "Bundled darwin helper not present; run resources/scripts/build.sh first"
        )

        // The helper derives its priority root from $HOME, so point it at a temp tree we control.
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        try createTestFile(in: home, name: "PWNotificationScript.csv", content: "body")
        let sub = try createTestFolder(in: home, name: "engagement")
        try createTestFile(in: sub, name: "passwordNotificationMail.ps1", content: "body")

        let matches = try runHelperFind(helper: helper, home: home, query: "notification")
            .flatMap { try RemoteFindCodec.decode($0) }
        let names = matches.map { ($0.path.lossyDisplayString as NSString).lastPathComponent }

        XCTAssertTrue(names.contains("PWNotificationScript.csv"), "top-level name match returned; got \(names)")
        XCTAssertTrue(names.contains("passwordNotificationMail.ps1"), "nested name match returned; got \(names)")
    }

    private func runHelperFind(helper: URL, home: URL, query: String) throws -> [Data] {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = helper
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let request = RPCEnvelope(
            id: 1,
            kind: .request,
            messageType: "Find",
            sequence: 0,
            isFinal: true,
            payload: try RPCMessage.find(query: Data(query.utf8), cap: 500).binaryEncoded()
        )
        stdin.fileHandleForWriting.write(try RPCStreamHandler.encodeFrame(request.encodedPayload()))
        try stdin.fileHandleForWriting.close()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var stream = RPCStreamHandler()
        let frames: [Data] = try stream.append(outData)
        var envelopes: [RPCEnvelope] = try frames.map { try RPCEnvelope(encodedPayload: $0) }
        envelopes = envelopes.filter { $0.id == 1 && $0.kind == .response }
        envelopes.sort { $0.sequence < $1.sequence }
        return envelopes.map { $0.payload }
    }
}
