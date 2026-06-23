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

        let names = try runHelperFind(helper: helper, home: home, query: "notification")
            .map { ($0.path.lossyDisplayString as NSString).lastPathComponent }

        XCTAssertTrue(names.contains("PWNotificationScript.csv"), "top-level name match returned; got \(names)")
        XCTAssertTrue(names.contains("passwordNotificationMail.ps1"), "nested name match returned; got \(names)")
    }

    /// Reads the streamed response incrementally and stops as soon as the home-pass matches arrive,
    /// terminating the helper instead of waiting for the whole-host pass. This both keeps the test
    /// fast and confirms results stream progressively.
    private func runHelperFind(helper: URL, home: URL, query: String) throws -> [RemoteFindMatch] {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = helper
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

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

        var stream = RPCStreamHandler()
        var matches: [RemoteFindMatch] = []
        let handle = stdout.fileHandleForReading
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            for frame in try stream.append(chunk) {
                let envelope = try RPCEnvelope(encodedPayload: frame)
                guard envelope.id == 1, envelope.kind == .response else { continue }
                matches.append(contentsOf: try RemoteFindCodec.decode(envelope.payload))
            }
            // Both home-pass matches in hand: stop without waiting for the whole-host pass.
            let names = Set(matches.map { ($0.path.lossyDisplayString as NSString).lastPathComponent })
            if names.isSuperset(of: ["PWNotificationScript.csv", "passwordNotificationMail.ps1"]) {
                break
            }
        }
        return matches
    }
}
