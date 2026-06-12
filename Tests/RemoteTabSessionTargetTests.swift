import XCTest
@testable import Detours

final class RemoteTabSessionTargetTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let hostID = UUID()
        let targets: [RemoteTabSessionTarget?] = [
            nil,
            RemoteTabSessionTarget(hostID: hostID, path: "/home/marco/projects"),
            nil,
        ]

        let decoded = RemoteTabSessionTarget.decode(RemoteTabSessionTarget.encode(targets), count: 3)

        XCTAssertEqual(decoded, targets)
    }

    func testDecodeCountMismatchYieldsAllLocal() {
        let encoded = RemoteTabSessionTarget.encode([RemoteTabSessionTarget(hostID: UUID(), path: "/srv")])

        let decoded = RemoteTabSessionTarget.decode(encoded, count: 2)

        XCTAssertEqual(decoded, [nil, nil])
    }

    func testDecodeMissingDataYieldsAllLocal() {
        XCTAssertEqual(RemoteTabSessionTarget.decode(nil, count: 2), [nil, nil])
    }

    func testDecodeMalformedEntryYieldsLocalTab() {
        let malformed: [[String: String]] = [
            ["hostID": "not-a-uuid", "path": "/srv"],
            ["path": "/srv"],
            ["hostID": UUID().uuidString],
        ]

        let decoded = RemoteTabSessionTarget.decode(malformed, count: 3)

        XCTAssertEqual(decoded, [nil, nil, nil])
    }
}
