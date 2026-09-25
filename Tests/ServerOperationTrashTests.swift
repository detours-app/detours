import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationTrashTests: XCTestCase {
    func testReservationPrecedesCreationAndPreservesOriginalPathBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = OperationLocation(account: fixture.account, path: .unix(Data([47, 104, 111, 109, 101, 47, 255, 10, 37])))
        let reservation = try fixture.store.plan(id: .init(operation: UUID(), item: UUID()), original: original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
        let effect = try fixture.store.prepare(reservation)
        let information = try fixture.url(reservation.information)
        let contents = try String(contentsOf: information, encoding: .utf8)
        XCTAssertTrue(contents.contains("Path=/home/%FF%0A%25\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.url(reservation.item).path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: information.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try fixture.store.prepare(reservation))
        XCTAssertEqual(try String(contentsOf: information, encoding: .utf8), contents)
        try fixture.store.removeInformation(effect, reservation: reservation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: information.path))
    }

    func testInformationCleanupRefusesAReplacedObject() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reservation = try fixture.store.plan(id: .init(operation: UUID(), item: UUID()), original: fixture.original)
        let effect = try fixture.store.prepare(reservation)
        let information = try fixture.url(reservation.information)
        let preserved = fixture.root.appendingPathComponent("preserved-info")
        try FileManager.default.moveItem(at: information, to: preserved)
        try Data("unowned file".utf8).write(to: information)
        XCTAssertThrowsError(try fixture.store.removeInformation(effect, reservation: reservation)) { error in
            XCTAssertEqual(error as? OperationFilesystemError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: information), Data("unowned file".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
    }

    func testExistingMovedItemAndNonPrivateTrashAreRefused() throws {
        for occupied in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let reservation = try fixture.store.plan(id: .init(operation: UUID(), item: UUID()), original: fixture.original)
            let item = try fixture.url(reservation.item)
            let trash = fixture.root.appendingPathComponent(".local/share/Trash")
            try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if occupied {
                try Data("existing item".utf8).write(to: item)
            } else {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path)
            }
            XCTAssertThrowsError(try fixture.store.prepare(reservation))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.url(reservation.information).path))
            if occupied { XCTAssertEqual(try Data(contentsOf: item), Data("existing item".utf8)) }
        }
    }

    private struct Fixture {
        let root: URL
        let account = OperationAccount(hostIdentity: "fixture", accountIdentity: "fixture-user")
        var store: ServerOperationTrash { ServerOperationTrash(homeDirectory: root, account: account) }
        var original: OperationLocation { OperationLocation(account: account, path: .unix(Data(root.appendingPathComponent("source").path.utf8))) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }

        func url(_ location: OperationLocation) throws -> URL {
            guard case .unix(let bytes) = location.path else { throw OperationFilesystemError.invalidPath }
            return URL(fileURLWithPath: try XCTUnwrap(String(data: bytes, encoding: .utf8)))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
