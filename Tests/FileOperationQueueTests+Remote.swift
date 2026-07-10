import XCTest
@testable import Detours

extension FileOperationQueueTests {
    func testFastLaneRefusesRemoteSource() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = try createTestFolder(in: temp, name: "Dest")
        let hostID = UUID()
        let remoteSource = Location.remote(hostID: hostID, path: "/home/marco/a.txt")

        let isFastLane = await FileOperationQueue.shared.isFastLaneCandidateForTesting(
            sources: [remoteSource],
            destination: .local(destination)
        )

        XCTAssertFalse(isFastLane)
    }

    func testFastLaneRefusesRemoteDestination() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "a.txt", content: "hello")
        let hostID = UUID()
        let remoteDestination = Location.remote(hostID: hostID, path: "/home/marco")

        let isFastLane = await FileOperationQueue.shared.isFastLaneCandidateForTesting(
            sources: [.local(source)],
            destination: remoteDestination
        )

        XCTAssertFalse(isFastLane)
    }

}
