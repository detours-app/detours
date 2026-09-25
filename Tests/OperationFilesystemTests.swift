import Foundation
import RemoteOperationSupport
import XCTest

final class OperationFilesystemTests: XCTestCase {
    func testOwnedArchiveOutputsPreserveHardLinksAndMetadata() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let payload = Data("payload".utf8)
        let alias = Data("alias".utf8)
        try workspace.createFile(named: payload).close()
        let output = try workspace.openEmptyFileForWriting(named: payload)
        try output.write(contentsOf: Data("owned content".utf8))
        try output.close()
        XCTAssertThrowsError(try workspace.openEmptyFileForWriting(named: payload))
        try workspace.createHardLink(named: alias, to: payload)
        XCTAssertEqual(try workspace.directory.observe(payload).identity, try workspace.directory.observe(alias).identity)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try workspace.applyMetadata(named: payload, mode: 0o100640, modified: modified)
        let url = URL(fileURLWithPath: try XCTUnwrap(String(data: try workspace.directory.childPath(alias), encoding: .utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(attributes[.modificationDate] as? Date, modified)
        XCTAssertEqual(try Data(contentsOf: url), Data("owned content".utf8))
        let saved = try JSONEncoder().encode(workspace.record)
        let reopened = try OperationWorkspace(parent: directory, record: JSONDecoder().decode(OperationWorkspace.Record.self, from: saved))
        try reopened.removeScratch()
        XCTAssertEqual(try directory.names(), [])
    }

    func testOwnedLinkTimestampDoesNotFollowTargetAndRefusesSubstitution() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let before = try directory.observe(Data("outside".utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let link = Data("link".utf8)
        try workspace.createSymbolicLink(named: link, target: Data(outside.path.utf8))
        let original = try workspace.directory.observe(link)
        try workspace.applyMetadata(named: link, mode: 0o120777, modified: Date(timeIntervalSince1970: 1_600_000_000))
        let updated = try workspace.directory.observe(link)
        XCTAssertEqual(updated.identity, original.identity)
        XCTAssertNotEqual(updated.version, original.version)
        XCTAssertEqual(try directory.observe(Data("outside".utf8)), before)
        let linkURL = URL(fileURLWithPath: try XCTUnwrap(String(data: try workspace.directory.childPath(link), encoding: .utf8)))
        try FileManager.default.moveItem(at: linkURL, to: root.appendingPathComponent("saved-link"))
        try Data("substitute".utf8).write(to: linkURL)
        XCTAssertThrowsError(try workspace.applyMetadata(named: link, mode: 0o600, modified: Date()))
        XCTAssertThrowsError(try workspace.createHardLink(named: Data("alias".utf8), to: link))
        XCTAssertEqual(try Data(contentsOf: linkURL), Data("substitute".utf8))
        XCTAssertEqual(try directory.observe(Data("outside".utf8)), before)
    }

    func testOwnedOutputRefusesReplacedEmptyFile() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let payload = Data("payload".utf8)
        try workspace.createFile(named: payload).close()
        let output = URL(fileURLWithPath: try XCTUnwrap(String(data: try workspace.directory.childPath(payload), encoding: .utf8)))
        try FileManager.default.moveItem(at: output, to: root.appendingPathComponent("saved"))
        try Data().write(to: output)
        XCTAssertThrowsError(try workspace.openEmptyFileForWriting(named: payload))
        XCTAssertThrowsError(try workspace.createHardLink(named: Data("alias".utf8), to: payload))
        XCTAssertThrowsError(try workspace.applyMetadata(named: payload, mode: 0o777, modified: Date()))
        XCTAssertEqual(try Data(contentsOf: output), Data())
    }

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

    func testPublicationPreservesIdentityAndNativeNameBytes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        #if os(Linux)
        let name = Data([0xff, 0x80])
        #else
        let name = Data("payload-ä".utf8)
        XCTAssertThrowsError(try workspace.createFile(named: Data([0xff, 0x80]))) {
            XCTAssertEqual($0 as? OperationFilesystemError, .system(92))
        }
        XCTAssertEqual(try workspace.directory.names(), [])
        #endif
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

    func testNestedOwnedCleanupPreservesLinkTargetsAndReopensItsLedger() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let outside = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        try workspace.createDirectory(named: Data("tree".utf8))
        try workspace.createDirectory(named: Data("tree/empty".utf8))
        let payload = Data("tree/file".utf8)
        let handle = try workspace.createFile(named: payload)
        try handle.write(contentsOf: Data("owned".utf8))
        try handle.close()
        try workspace.synchronizeFile(named: payload)
        try workspace.createSymbolicLink(named: Data("tree/link".utf8), target: Data(outside.path.utf8))
        let saved = try JSONEncoder().encode(workspace.record)
        let record = try JSONDecoder().decode(OperationWorkspace.Record.self, from: saved)
        let reopened = try OperationWorkspace(parent: directory, record: record)
        XCTAssertEqual(record.objects.count, 4)
        for path in ["tree/../escape", "tree//escape", "tree/link/escape", "/absolute"] {
            XCTAssertThrowsError(try reopened.createFile(named: Data(path.utf8)))
        }
        try reopened.removeScratch()
        XCTAssertEqual(try directory.names(), [Data("outside".utf8)])
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testUnknownNestedChildPreventsAnyCleanup() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        try workspace.createDirectory(named: Data("tree".utf8))
        try workspace.createFile(named: Data("tree/owned".utf8)).close()
        let workspaceURL = URL(fileURLWithPath: try XCTUnwrap(String(data: workspace.directory.path, encoding: .utf8)))
        let foreign = workspaceURL.appendingPathComponent("tree/foreign")
        try Data("keep foreign".utf8).write(to: foreign)
        let tree = foreign.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tree.path)
        defer { XCTAssertNoThrow(try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tree.path)) }
        XCTAssertThrowsError(try workspace.removeScratch()) {
            XCTAssertEqual($0 as? OperationFilesystemError, .unexpectedContents)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("tree/owned").path))
        XCTAssertEqual(try Data(contentsOf: foreign), Data("keep foreign".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: tree.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)
    }

    func testReplacedNestedDirectoryIsNeverAdoptedForCreationOrCleanup() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        try workspace.createDirectory(named: Data("tree".utf8))
        try workspace.createFile(named: Data("tree/owned".utf8)).close()
        let workspaceURL = URL(fileURLWithPath: try XCTUnwrap(String(data: workspace.directory.path, encoding: .utf8)))
        let tree = workspaceURL.appendingPathComponent("tree")
        let preserved = root.appendingPathComponent("preserved")
        try FileManager.default.moveItem(at: tree, to: preserved)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: tree.appendingPathComponent("owned"))
        XCTAssertThrowsError(try workspace.createFile(named: Data("tree/new".utf8))) {
            XCTAssertEqual($0 as? OperationFilesystemError, .identityChanged)
        }
        XCTAssertThrowsError(try workspace.removeScratch()) {
            XCTAssertEqual($0 as? OperationFilesystemError, .identityChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.appendingPathComponent("owned").path))
        XCTAssertEqual(try Data(contentsOf: tree.appendingPathComponent("owned")), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.appendingPathComponent("new").path))
    }

    func testDirectoryMetadataIsPreservedAndOwnedReadOnlyScratchCanBeCleaned() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o555, .modificationDate: modified], ofItemAtPath: original.path)
        let parent = try OperationDirectory(path: Data(root.path.utf8))
        let source = try OperationDirectory(path: Data(original.path.utf8))
        let workspace = try OperationWorkspace(parent: parent, id: .init(operation: UUID(), item: UUID()))
        try workspace.createDirectory(named: Data("tree".utf8))
        try workspace.createFile(named: Data("tree/file".utf8)).close()
        let destination = try OperationDirectory(path: workspace.directory.childPath(Data("tree".utf8)))
        try source.copyMetadata(to: destination)
        let path = try XCTUnwrap(String(data: destination.path, encoding: .utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o555)
        XCTAssertEqual(attributes[.modificationDate] as? Date, modified)
        try workspace.removeScratch()
        XCTAssertEqual(try parent.names(), [Data("original".utf8)])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
