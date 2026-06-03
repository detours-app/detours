import XCTest
@testable import Detours

final class LocationTests: XCTestCase {
    func testLocalRoundTrip() throws {
        let location = Location.local(URL(fileURLWithPath: "/tmp/detours/a.txt"))

        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(Location.self, from: data)

        XCTAssertEqual(decoded, location)
    }

    func testRemoteRoundTrip() throws {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/home/marco/project")

        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(Location.self, from: data)

        XCTAssertEqual(decoded, location)
    }

    func testPathManipulation() {
        let local = Location.local(URL(fileURLWithPath: "/tmp/detours"))
        XCTAssertEqual(local.appendingPathComponent("child").path, "/tmp/detours/child")
        XCTAssertEqual(local.appendingPathComponent("child").deletingLastPathComponent(), local)
        XCTAssertEqual(local.appendingPathComponent("child").parent, local)

        let hostID = UUID()
        let remote = Location.remote(hostID: hostID, path: "/home/marco")
        XCTAssertEqual(remote.appendingPathComponent("repo").path, "/home/marco/repo")
        XCTAssertEqual(remote.appendingPathComponent("repo").deletingLastPathComponent(), remote)
        XCTAssertEqual(remote.appendingPathComponent("repo").parent, remote)
    }
}
