import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteOperationStoreTests: XCTestCase {
    func testRestartRetainsIntentSentPhaseAndCancellation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RemoteOperationStore(root: root)
        var snapshot = try makeSnapshot()
        snapshot = try store.save(snapshot)
        snapshot.items[0].sent.insert(.accept)
        snapshot.items[0].pending = .accept
        try snapshot.items[0].result.markSubmitted()
        snapshot.record.requestCancellation()
        snapshot.items[0].result.requestCancellation()
        snapshot = try store.save(snapshot)
        let restarted = try RemoteOperationStore(root: root)
        XCTAssertEqual(try restarted.load(snapshot.record.operation), snapshot)
        XCTAssertEqual(try restarted.all(), [snapshot])
        XCTAssertFalse(snapshot.items[0].result.maySubmit)
        XCTAssertEqual(snapshot.revision, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: recordURL(root, snapshot).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStaleWriterCannotEraseCancellationOrSubmittedMutation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RemoteOperationStore(root: root)
        let second = try RemoteOperationStore(root: root)
        let stale = try first.save(makeSnapshot())
        var updated = stale
        updated.record.requestCancellation()
        updated.items[0].result.requestCancellation()
        updated = try second.save(updated)
        XCTAssertThrowsError(try first.save(stale)) { error in
            XCTAssertEqual(error as? RemoteOperationStore.StoreError, .staleRevision)
        }
        XCTAssertEqual(try first.load(updated.record.operation), updated)
    }

    func testAcceptedIntentCannotBeRewrittenOrReordered() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RemoteOperationStore(root: root)
        let saved = try store.save(makeSnapshot())
        var changed = try makeSnapshot(operation: saved.record.operation)
        changed.revision = saved.revision
        XCTAssertThrowsError(try store.save(changed)) { error in
            XCTAssertEqual(error as? OperationContractError, .intentMismatch)
        }
        XCTAssertEqual(try store.load(saved.record.operation), saved)
    }

    func testMissingOrCorruptRecordDoesNotPermitOverwrite() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RemoteOperationStore(root: root)
        let saved = try store.save(makeSnapshot())
        let url = recordURL(root, saved)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store.load(saved.record.operation))
        XCTAssertThrowsError(try store.save(saved))
        try Data("broken record".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertThrowsError(try store.load(saved.record.operation))
        XCTAssertThrowsError(try store.save(saved))
        XCTAssertEqual(try Data(contentsOf: url), Data("broken record".utf8))
        XCTAssertThrowsError(try store.all())
    }

    func testIncompleteSnapshotCannotReplaceLastDurableState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RemoteOperationStore(root: root)
        let saved = try store.save(makeSnapshot())
        let incomplete = root.appendingPathComponent(UUID().uuidString + ".snapshot")
        try Data("{\"revision\":".utf8).write(to: incomplete)
        let restarted = try RemoteOperationStore(root: root)
        XCTAssertEqual(try restarted.all(), [saved])
        XCTAssertEqual(try Data(contentsOf: incomplete), Data("{\"revision\":".utf8))
    }

    func testReplacedDirectoryAndLinkedRecordAreRefused() throws {
        let root = try temporaryRoot()
        let moved = root.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let store = try RemoteOperationStore(root: root)
        let saved = try store.save(makeSnapshot())
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try store.save(saved))
        let next = try RemoteOperationStore(root: root)
        try FileManager.default.createSymbolicLink(at: recordURL(root, saved),
                                                   withDestinationURL: recordURL(moved, saved))
        XCTAssertThrowsError(try next.load(saved.record.operation))
        XCTAssertThrowsError(try next.save(saved))
        XCTAssertEqual(try RemoteOperationStore(root: moved).load(saved.record.operation), saved)
    }

    func testPublicStoreIsRefused() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try RemoteOperationStore(root: root))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteStore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    private func recordURL(_ root: URL, _ snapshot: RemoteOperationStore.Snapshot) -> URL {
        root.appendingPathComponent(snapshot.record.operation.uuidString.lowercased() + ".json")
    }

    private func makeSnapshot(operation: UUID = UUID()) throws -> RemoteOperationStore.Snapshot {
        let account = OperationAccount(hostIdentity: "verified-host", accountIdentity: "uid:1000")
        let intent = OperationIntent(id: OperationItemID(operation: operation, item: UUID()), action: .createFolder,
                                     sources: [], destination: OperationLocation(account: account, path: .unix(Data([47, 255]))),
                                     sourceObservations: [], conflict: .createNew)
        var snapshot = RemoteOperationStore.Snapshot(operation: operation)
        try snapshot.record.accept(intent)
        snapshot.items.append(.init(hostID: UUID(), result: OperationOutcomeReducer(
            intent: intent, account: account, epoch: UUID(), intentDigest: "digest"
        )))
        return snapshot
    }
}
