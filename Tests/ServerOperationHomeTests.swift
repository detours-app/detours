import RemoteOperationSupport
import XCTest
@testable import detours_server

/// `--operation-home` keeps the helper's operation journal and trash under a chosen folder,
/// which the app's UI tests use to stay inside their run root.
final class ServerOperationHomeTests: XCTestCase {
    func testOperationHomeArgumentIsParsed() throws {
        XCTAssertNil(try Daemon.operationHomeDirectory(in: ["detours-server"]))
        XCTAssertEqual(
            try Daemon.operationHomeDirectory(in: ["detours-server", "--operation-home", "/tmp/home"])?.path,
            "/tmp/home"
        )
    }

    func testOperationHomeArgumentRequiresAnAbsolutePath() {
        XCTAssertThrowsError(try Daemon.operationHomeDirectory(in: ["detours-server", "--operation-home"]))
        XCTAssertThrowsError(try Daemon.operationHomeDirectory(in: ["detours-server", "--operation-home", "relative"]))
    }

    func testLiveServiceKeepsItsJournalUnderTheOperationHome() async throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }

        let service = try await ServerOperationService.live(homeDirectory: home)
        guard case .handshake = try await service.reply(to: .handshake) else {
            return XCTFail("The live service did not answer the handshake")
        }

        let journal = home.appendingPathComponent(".detours-server/operations")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path), "No journal under \(journal.path)")
        XCTAssertEqual(service.trashStore.homeDirectory.standardizedFileURL, home.standardizedFileURL)
    }
}
