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

    func testInterruptedSnapshotWriteLeavesTheLastDurableState() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await OperationJournal(root: root, account: account)
        let intent = makeIntent()
        let ownership = try await journal.acquireItem(intent.id)
        let accepted = try journal.accept(intent, digest: "digest", ownership: ownership)

        // A snapshot write killed before its atomic rename leaves a temporary beside the record.
        let interrupted = root.appendingPathComponent(UUID().uuidString.lowercased() + ".snapshot")
        try Data("half a snapshot".utf8).write(to: interrupted)

        XCTAssertEqual(try journal.read(intent.id), accepted)
        XCTAssertEqual(try journal.accept(intent, digest: "digest", ownership: ownership), accepted)

        // The temporary is never read as a record, and the accepted intent survives a reopen, so a
        // sent mutation is never silently reset to something safe to replay.
        let reopened = try await OperationJournal(root: root, account: account)
        XCTAssertEqual(try reopened.read(intent.id), accepted)
        withExtendedLifetime(ownership) {}
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

    func testStoppedUnknownReceiptCanBeReconciledWithoutResubmission() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await OperationJournal(root: root, account: account)
        let intent = makeIntent()
        let ownership = try await journal.acquireItem(intent.id)
        _ = try journal.accept(intent, digest: "digest", ownership: ownership)
        try journal.record(OperationReceipt(
            id: intent.id, account: account, epoch: journal.epoch, intentDigest: "digest",
            revision: 1, phase: .terminal, outcome: .unknown
        ), ownership: ownership)
        try journal.record(OperationReceipt(
            id: intent.id, account: account, epoch: journal.epoch, intentDigest: "digest",
            revision: 2, phase: .terminal, outcome: .failedUnchanged
        ), ownership: ownership)
        XCTAssertEqual(try journal.read(intent.id).receipt?.outcome, .failedUnchanged)
        XCTAssertEqual(try journal.read(intent.id).revision, 3)
    }

    func testManifestsRemainImmutableAcrossReceiptWorkspaceAndReopen() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await OperationJournal(root: root.appendingPathComponent("journal"), account: account)
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        try Data("source".utf8).write(to: root.appendingPathComponent("source"))
        try Data("source".utf8).write(to: root.appendingPathComponent("payload"))
        let source = try directory.manifest(Data("source".utf8), progress: { _ in })
        let payload = try directory.manifest(Data("payload".utf8), progress: { _ in })
        let intent = makeIntent()
        let ownership = try await journal.acquireItem(intent.id)
        _ = try journal.accept(intent, digest: "digest", ownership: ownership)
        try journal.recordManifests(intent.id, source: source, payload: nil, archiveInputs: source, ownership: ownership)
        XCTAssertEqual(try journal.read(intent.id).sourceManifest, source)
        XCTAssertNil(try journal.read(intent.id).payloadManifest)
        let workspace = try OperationWorkspace(parent: directory, id: intent.id)
        try journal.recordWorkspace(workspace.record, ownership: ownership)
        try journal.recordManifests(intent.id, source: source, payload: payload, archiveInputs: source, ownership: ownership)
        let receipt = OperationReceipt(id: intent.id, account: account, epoch: journal.epoch, intentDigest: "digest",
                                       revision: 1, phase: .preparing, outcome: .running)
        try journal.record(receipt, ownership: ownership)
        let reopened = try await OperationJournal(root: root.appendingPathComponent("journal"), account: account)
        let retained = try reopened.read(intent.id)
        XCTAssertEqual(retained.sourceManifest, source)
        XCTAssertEqual(retained.archiveInputManifest, source)
        XCTAssertEqual(retained.payloadManifest, payload)
        XCTAssertEqual(retained.workspace, workspace.record)
        XCTAssertEqual(retained.receipt, receipt)
        try journal.recordManifests(intent.id, source: source, payload: payload, archiveInputs: source, ownership: ownership)
        XCTAssertEqual(try journal.read(intent.id), retained)
        XCTAssertThrowsError(try journal.recordManifests(intent.id, source: payload, payload: payload, archiveInputs: source, ownership: ownership))
        XCTAssertThrowsError(try journal.recordManifests(intent.id, source: source, payload: source, archiveInputs: source, ownership: ownership))
        XCTAssertThrowsError(try journal.recordManifests(intent.id, source: source, payload: nil, archiveInputs: source, ownership: ownership))
        XCTAssertThrowsError(try journal.recordManifests(intent.id, source: source, payload: payload, archiveInputs: payload, ownership: ownership))
        XCTAssertThrowsError(try journal.recordManifests(intent.id, source: source, payload: payload, ownership: ownership))
        XCTAssertEqual(try journal.read(intent.id), retained)
        try workspace.removeScratch()
        let terminal = OperationReceipt(id: intent.id, account: account, epoch: journal.epoch, intentDigest: "digest",
                                        revision: 2, phase: .terminal, outcome: .failedUnchanged)
        try journal.record(terminal, ownership: ownership)
        XCTAssertThrowsError(try journal.recordManifests(intent.id, source: source, payload: payload, archiveInputs: source, ownership: ownership))
        try journal.acknowledge(intent.id, retainingUndo: false, ownership: ownership)
        let compacted = try journal.read(intent.id)
        XCTAssertNil(compacted.sourceManifest)
        XCTAssertNil(compacted.archiveInputManifest)
        XCTAssertNil(compacted.payloadManifest)
        XCTAssertEqual(compacted.receipt, terminal)
        XCTAssertThrowsError(try journal.recordManifests(intent.id, source: source, payload: payload, archiveInputs: source, ownership: ownership))
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
