import Foundation
import RemoteOperationSupport
import XCTest

final class RemoteOperationJournalTests: XCTestCase {
    private let account = OperationAccount(hostIdentity: "host-key", accountIdentity: "uid:1000")

    func testAcceptedIntentAndEpochSurviveReopening() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await OperationJournal(root: root, account: account)
        let intent = makeIntent()
        let ownership = try await journal.acquireItem(intent.id)
        let accepted = try journal.accept(intent, digest: "digest", ownership: ownership)
        let reopened = try await OperationJournal(root: root, account: account)
        XCTAssertEqual(reopened.epoch, journal.epoch)
        XCTAssertEqual(try reopened.read(intent.id), accepted)
        XCTAssertEqual(try journal.accept(intent, digest: "digest", ownership: ownership), accepted)
        XCTAssertThrowsError(try journal.accept(intent, digest: "changed-digest", ownership: ownership))
        withExtendedLifetime(ownership) {}
    }

    func testStatusAndCancellationRemainAvailableWhileWorkerOwnsItem() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await OperationJournal(root: root, account: account)
        let control = try await OperationJournal(root: root, account: account)
        let intent = makeIntent()
        let ownership = try await journal.acquireItem(intent.id)
        let accepted = try journal.accept(intent, digest: "digest", ownership: ownership)
        try control.requestCancellation(intent.id)
        XCTAssertTrue(try journal.cancellationRequested(intent.id))
        XCTAssertEqual(try control.read(intent.id), accepted)
        let blocked = Task { try await control.acquireItem(intent.id) }
        blocked.cancel()
        do {
            _ = try await blocked.value
            XCTFail("A cancelled competing worker acquired ownership")
        } catch is CancellationError {
            XCTAssertEqual(try control.read(intent.id), accepted)
        }
        withExtendedLifetime(ownership) {}
    }

    func testTombstoneRetainsTerminalResultAndRejectsChangedIntent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await OperationJournal(root: root, account: account)
        let intent = makeIntent()
        let ownership = try await journal.acquireItem(intent.id)
        _ = try journal.accept(intent, digest: "digest", ownership: ownership)
        let receipt = OperationReceipt(
            id: intent.id, account: account, epoch: journal.epoch, intentDigest: "digest",
            revision: 1, phase: .terminal, outcome: .failedUnchanged
        )
        try journal.record(receipt, ownership: ownership)
        XCTAssertThrowsError(try journal.acknowledge(intent.id, retainingUndo: true, ownership: ownership))
        try journal.acknowledge(intent.id, retainingUndo: false, ownership: ownership)
        let tombstone = try journal.read(intent.id)
        XCTAssertNil(tombstone.intent)
        XCTAssertTrue(tombstone.acknowledged)
        XCTAssertEqual(tombstone.receipt, receipt)
        XCTAssertEqual(tombstone.revision, 3)
        XCTAssertEqual(try journal.accept(intent, digest: "digest", ownership: ownership), tombstone)
        XCTAssertThrowsError(try journal.accept(intent, digest: "different", ownership: ownership))
        XCTAssertThrowsError(try journal.record(receipt, ownership: ownership))
    }

    func testMissingCorruptAndOldEpochRecordsRemainErrors() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await OperationJournal(root: root, account: account)
        let intent = makeIntent()
        XCTAssertThrowsError(try journal.read(intent.id)) { error in
            XCTAssertEqual(error as? OperationJournalError, .missingRecord)
        }
        let ownership = try await journal.acquireItem(intent.id)
        _ = try journal.accept(intent, digest: "digest", ownership: ownership)
        try FileManager.default.removeItem(at: root.appendingPathComponent("epoch.json"))
        let reset = try await OperationJournal(root: root, account: account)
        XCTAssertNotEqual(reset.epoch, journal.epoch)
        XCTAssertThrowsError(try reset.read(intent.id)) { error in
            XCTAssertEqual(error as? OperationContractError, .epochMismatch)
        }
        let filename = intent.id.operation.uuidString.lowercased() + "-" + intent.id.item.uuidString.lowercased() + ".json"
        try Data("broken".utf8).write(to: root.appendingPathComponent(filename))
        XCTAssertThrowsError(try journal.read(intent.id))
        XCTAssertThrowsError(try journal.accept(intent, digest: "digest", ownership: ownership))
    }

    func testJournalRejectsPublicDirectoryAndSymbolicLink() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        do {
            _ = try await OperationJournal(root: root, account: account)
            XCTFail("A public journal directory was accepted")
        } catch {
            XCTAssertEqual(error as? OperationJournalError, .unsafeObject)
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        do {
            _ = try await OperationJournal(root: link, account: account)
            XCTFail("A linked journal directory was accepted")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testAnotherItemsOwnershipCannotWriteReceipt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await OperationJournal(root: root, account: account)
        let first = makeIntent()
        let second = makeIntent()
        let ownership = try await journal.acquireItem(first.id)
        XCTAssertThrowsError(try journal.accept(second, digest: "digest", ownership: ownership)) { error in
            XCTAssertEqual(error as? OperationContractError, .identityMismatch)
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func makeIntent() -> OperationIntent {
        OperationIntent(
            id: .init(operation: UUID(), item: UUID()), action: .copy, sources: [],
            destination: OperationLocation(account: account, path: .unix(Data("/destination".utf8))),
            sourceObservations: [], conflict: .createNew
        )
    }
}
