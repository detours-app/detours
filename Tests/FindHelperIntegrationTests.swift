import XCTest
@testable import Detours

/// Drives the actual compiled `detours-server` helper binary over the framed RPC protocol and
/// confirms a `find` request returns matches. This exercises the whole find path end to end
/// (client message encode -> wire frame -> helper RPC dispatch -> FindOperations traversal ->
/// result-chunk decode) against the real binary, not just the unit-level pieces.
final class FindHelperIntegrationTests: XCTestCase {
    func testFindReturnsMatchesFromRealHelperBinary() throws {
        // Prefer the natively-built helper (matches the test host's architecture); fall back to the
        // bundled cross-compiled copies only if a native build product is not present.
        let candidates = [
            ".build/debug/detours-server",
            ".build/release/detours-server",
        ]
        guard let helperPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("No native detours-server build product found; run swift test from the package root")
        }
        let helper = URL(fileURLWithPath: helperPath)

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
