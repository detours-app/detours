import XCTest
@testable import Detours

extension RemoteIntegrationTests {
    func testRepeatedGitRefreshReleasesHelperDescriptors() async throws {
        _ = try await RemoteIntegrationSession.make()
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH("git init -q \(Self.shellQuote(root))")

        let session = try PersistentRemoteRPCSession.start()
        defer { session.close() }
        var requestID: UInt64 = 0

        func request(_ message: RPCMessage) throws -> Data {
            requestID += 1
            let id = requestID
            try session.send(message, id: id)
            let response = try session.waitForEnvelope(timeout: 10) { $0.id == id }
            guard response.kind == .response else {
                throw RemoteFileProviderError.invalidResponse("Helper request failed: \(response)")
            }
            return response.payload
        }

        func descriptorCount() throws -> Int {
            let payload = try request(.list(path: RemotePath("/proc/self/fd"), showHidden: true))
            return try RemoteFileProvider.decodeFileEntries(payload).count
        }

        _ = try request(.gitStatus(directory: RemotePath(root)))
        let before = try descriptorCount()
        for _ in 0..<32 {
            _ = try request(.gitStatus(directory: RemotePath(root)))
        }
        let after = try descriptorCount()
        XCTAssertLessThanOrEqual(after, before + 2,
                                 "Repeated Git refreshes retained descriptors: \(before) -> \(after)")
        let listing = try request(.list(path: RemotePath(root), showHidden: true))
        XCTAssertFalse(try RemoteFileProvider.decodeFileEntries(listing).isEmpty)
    }
}
