import Foundation
import RemoteOperationSupport
import XCTest

final class OperationFilesystemTests: XCTestCase {
    func testCompetingDestinationIsNeverReplaced() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let payload = Data("payload".utf8)
        let handle = try workspace.createFile(named: payload)
        try handle.write(contentsOf: Data("incoming".utf8))
        try handle.close()
        try workspace.synchronizeFile(named: payload)
        let observation = try workspace.directory.observe(payload)
        let target = root.appendingPathComponent("destination")
        try Data("competitor".utf8).write(to: target)
        XCTAssertThrowsError(try workspace.directory.moveExclusive(payload, to: directory, named: Data("destination".utf8), expected: observation))
        XCTAssertEqual(try Data(contentsOf: target), Data("competitor".utf8))
        XCTAssertEqual(try workspace.directory.observe(payload), observation)
        try workspace.removeScratch()
    }

    func testPublicationPreservesIdentityAndInvalidUTF8Name() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let name = Data([0xff, 0x80])
        let file = try workspace.createFile(named: name)
        try file.write(contentsOf: Data("body".utf8))
        try file.close()
        try workspace.synchronizeFile(named: name)
        let before = try workspace.directory.observe(name)
        let after = try workspace.directory.moveExclusive(name, to: directory, named: name, expected: before)
        XCTAssertEqual(after.identity, before.identity)
        XCTAssertEqual(after.byteCount, 4)
        XCTAssertTrue(try directory.names().contains(name))
        try workspace.removeScratch()
        XCTAssertEqual(try directory.observe(name).identity, before.identity)
    }

    func testCleanupRetainsUnknownDescendantsAndRecordedPayload() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let payload = Data("payload".utf8)
        try workspace.createFile(named: payload).close()
        let workspacePath = try XCTUnwrap(String(data: workspace.directory.path, encoding: .utf8))
        let foreign = URL(fileURLWithPath: workspacePath).appendingPathComponent("foreign")
        try Data("user content".utf8).write(to: foreign)
        XCTAssertThrowsError(try workspace.removeScratch()) {
            XCTAssertEqual($0 as? OperationFilesystemError, .unexpectedContents)
        }
        XCTAssertEqual(try Data(contentsOf: foreign), Data("user content".utf8))
        XCTAssertEqual(try workspace.directory.observe(payload).identity, workspace.record.objects.first?.identity)
    }

    func testCleanupRejectsReplacedScratchIdentity() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let payload = Data("payload".utf8)
        try workspace.createFile(named: payload).close()
        let workspacePath = try XCTUnwrap(String(data: workspace.directory.path, encoding: .utf8))
        let file = URL(fileURLWithPath: workspacePath).appendingPathComponent("payload")
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original"))
        try Data("replacement".utf8).write(to: file)
        XCTAssertThrowsError(try workspace.removeScratch()) {
            XCTAssertEqual($0 as? OperationFilesystemError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
    }

    func testPersistedOwnershipSurvivesReopeningAndRejectsTraversal() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        try workspace.createFile(named: Data("payload".utf8)).close()
        let saved = try JSONEncoder().encode(workspace.record)
        let record = try JSONDecoder().decode(OperationWorkspace.Record.self, from: saved)
        let reopened = try OperationWorkspace(parent: directory, record: record)
        XCTAssertThrowsError(try reopened.createFile(named: Data("../escape".utf8)))
        XCTAssertThrowsError(try reopened.createFile(named: Data("payload".utf8)))
        try reopened.removeScratch()
        XCTAssertEqual(try directory.names(), [])
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
