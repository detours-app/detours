import XCTest
@testable import Detours

final class WindowsPathTests: XCTestCase {
    func testRoundTripsDriveAndProfilePaths() throws {
        let hostID = UUID()
        let path = try WindowsPath(remotePath: "/C:/Users/sans")

        XCTAssertEqual(path.remotePath, "/C:/Users/sans")
        XCTAssertEqual(path.nativePath, "C:\\Users\\sans")
        XCTAssertEqual(path.sftpPath, "C:/Users/sans")
        XCTAssertEqual(try WindowsPath.remotePath(fromNative: "C:\\Users\\sans"), "/C:/Users/sans")
        XCTAssertEqual(try WindowsPath.location(fromNative: "C:\\Users\\sans", hostID: hostID), .remote(hostID: hostID, path: "/C:/Users/sans"))

        let location = Location.remote(hostID: hostID, path: "/C:/Users/sans")
        XCTAssertEqual(try WindowsPath(location: location, hostID: hostID), path)
        XCTAssertEqual(location.appendingPathComponent("Desktop"), .remote(hostID: hostID, path: "/C:/Users/sans/Desktop"))
    }

    func testDriveRootDetectionAndUpNavigation() throws {
        let driveRoot = try WindowsPath(remotePath: "/C:/")
        let profile = try WindowsPath(remotePath: "/C:/Users/sans")
        let syntheticRoot = try WindowsPath(remotePath: "/")

        XCTAssertTrue(driveRoot.isDriveRoot)
        XCTAssertEqual(driveRoot.nativePath, "C:\\")
        XCTAssertEqual(driveRoot.sftpPath, "C:/")
        XCTAssertFalse(profile.isDriveRoot)
        XCTAssertTrue(syntheticRoot.isSyntheticRoot)
        XCTAssertNil(syntheticRoot.nativePath)
        XCTAssertEqual(driveRoot.parent.remotePath, "/")
        XCTAssertEqual(profile.parent.remotePath, "/C:/Users")
        XCTAssertEqual(try syntheticRoot.appending("D:").remotePath, "/D:")
    }
}
