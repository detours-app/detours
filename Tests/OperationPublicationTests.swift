import Foundation
@testable import RemoteOperationSupport
import XCTest

final class OperationPublicationTests: XCTestCase {
    func testReplacementRetainsOriginalOutsideScratchOwnership() async throws {
        let fixture = try await Fixture(replacing: true)
        defer { fixture.cleanup() }
        let ownership = try await fixture.prepare()
        let result = try await OperationPublication.publish(journal: fixture.journal, id: fixture.id, ownership: ownership)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data())
        let backup = try XCTUnwrap(result.recovery.first { $0.purpose == .displacedOriginal })
        XCTAssertNotNil(backup.knownLocation)
        XCTAssertEqual(try Data(contentsOf: fixture.holdingURL), Data("original".utf8))
        XCTAssertThrowsError(try fixture.workspace.removeScratch())
        XCTAssertEqual(try Data(contentsOf: fixture.holdingURL), Data("original".utf8))
    }

    func testReplacementRejectsAnUnapprovedDestinationVersion() async throws {
        let fixture = try await Fixture(replacing: true)
        defer { fixture.cleanup() }
        let ownership = try await fixture.prepare()
        try Data("edited original".utf8).write(to: fixture.destination)
        do {
            _ = try await OperationPublication.publish(journal: fixture.journal, id: fixture.id, ownership: ownership)
            XCTFail("An unapproved destination version was replaced")
        } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("edited original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.holdingURL.path))
        XCTAssertEqual(try fixture.journal.read(fixture.id).receipt?.phase, .readyToCommit)
    }

    func testReplacementRestorationNeverOverwritesANewOccupant() async throws {
        for occupied in [false, true] {
            let fixture = try await Fixture(replacing: true)
            defer { fixture.cleanup() }
            let ownership = try await fixture.prepare()
            let commit = try await fixture.journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            _ = try OperationReplacement.displace(journal: fixture.journal, snapshot: fixture.journal.read(fixture.id), ownership: ownership)
            if occupied { try Data("new occupant".utf8).write(to: fixture.destination) }
            try OperationReplacement.restore(journal: fixture.journal, id: fixture.id, ownership: ownership, failure: "publication stopped")
            let receipt = try XCTUnwrap(fixture.journal.read(fixture.id).receipt)
            XCTAssertEqual(receipt.outcome, .partial)
            XCTAssertTrue(receipt.effects.isEmpty)
            if occupied {
                XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("new occupant".utf8))
                XCTAssertEqual(try Data(contentsOf: fixture.holdingURL), Data("original".utf8))
                XCTAssertNotNil(receipt.recovery.first { $0.purpose == .displacedOriginal }?.knownLocation)
            } else {
                XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("original".utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.holdingURL.path))
                XCTAssertFalse(receipt.recovery.contains { $0.purpose == .displacedOriginal })
            }
        }
    }

    func testReplacementRestoresOriginalWhenPayloadPublicationFails() async throws {
        let fixture = try await Fixture(replacing: true)
        defer { fixture.cleanup() }
        let ownership = try await fixture.prepare()
        let payloadURL = fixture.holdingURL.deletingLastPathComponent().appendingPathComponent("payload")
        try Data("changed payload".utf8).write(to: payloadURL)
        do {
            _ = try await OperationPublication.publish(journal: fixture.journal, id: fixture.id, ownership: ownership)
            XCTFail("An altered payload was published")
        } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: payloadURL), Data("changed payload".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.holdingURL.path))
        let result = try XCTUnwrap(fixture.journal.read(fixture.id).receipt)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertFalse(result.recovery.contains { $0.purpose == .displacedOriginal })
    }

    func testPublicationRecordsActualIdentityAndCannotBeRepeated() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let ownership = try await fixture.prepare()
        let receipt = try await OperationPublication.publish(journal: fixture.journal, id: fixture.id, ownership: ownership)
        XCTAssertEqual(receipt.outcome, .committed)
        XCTAssertEqual(receipt.effects.first?.observation.identity, fixture.payload.observation.identity)
        XCTAssertEqual(try fixture.journal.read(fixture.id).receipt, receipt)
        do {
            _ = try await OperationPublication.publish(journal: fixture.journal, id: fixture.id, ownership: ownership)
            XCTFail("A committed payload was published twice")
        } catch { XCTAssertEqual(error as? OperationContractError, .invalidReceipt) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.workspace.removeScratch()
    }

    func testCancellationIsRereadBeforePublication() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let ownership = try await fixture.prepare()
        try fixture.journal.requestCancellation(fixture.id)
        do {
            _ = try await OperationPublication.publish(journal: fixture.journal, id: fixture.id, ownership: ownership)
            XCTFail("Cancellation was ignored")
        } catch { XCTAssertEqual(error as? OperationContractError, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try fixture.journal.read(fixture.id).receipt?.phase, .readyToCommit)
        XCTAssertEqual(try fixture.workspace.directory.observe(Data("payload".utf8)).identity, fixture.payload.observation.identity)
    }

    func testLostCommitConclusionRetainsBothPossibleLocations() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let ownership = try await fixture.prepare()
        try Data("competitor".utf8).write(to: fixture.destination)
        do {
            _ = try await OperationPublication.publish(journal: fixture.journal, id: fixture.id, ownership: ownership)
            XCTFail("A competing destination was overwritten")
        } catch {
            XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("competitor".utf8))
        }
        let receipt = try XCTUnwrap(fixture.journal.read(fixture.id).receipt)
        XCTAssertEqual(receipt.phase, .committing)
        XCTAssertEqual(receipt.recovery.first?.possibleLocations.count, 2)
        XCTAssertNil(receipt.recovery.first?.knownLocation)
        XCTAssertTrue(receipt.effects.isEmpty)
    }

    private struct Fixture {
        let root: URL
        let destination: URL
        let id = OperationItemID(operation: UUID(), item: UUID())
        let journal: OperationJournal
        let workspace: OperationWorkspace
        let payload: OperationEffect
        let intent: OperationIntent

        let holdingURL: URL

        init(replacing: Bool = false) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.root = root
            self.destination = root.appendingPathComponent("final")
            let account = OperationAccount(hostIdentity: "fixture-host", accountIdentity: "fixture-account")
            self.journal = try await OperationJournal(root: root.appendingPathComponent("journal"), account: account)
            let directory = try OperationDirectory(path: Data(root.path.utf8))
            var conflict = OperationIntent.Conflict.createNew
            if replacing {
                try Data("original".utf8).write(to: destination)
                conflict = .replace(try directory.observe(Data("final".utf8)))
            }
            let workspace = try OperationWorkspace(parent: directory, id: id)
            self.workspace = workspace
            self.holdingURL = root.appendingPathComponent(try XCTUnwrap(String(data: workspace.record.root.name, encoding: .utf8)))
                .appendingPathComponent("displaced")
            let name = Data("payload".utf8)
            try workspace.createFile(named: name).close()
            try workspace.synchronizeFile(named: name)
            let observation = try workspace.directory.observe(name)
            let proof = OperationObservation(
                identity: observation.identity, kind: .file, version: observation.version, byteCount: 0,
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", linkTarget: nil
            )
            self.payload = OperationEffect(location: OperationLocation(account: account, path: .unix(try workspace.directory.childPath(name))),
                                           observation: proof)
            self.intent = OperationIntent(id: id, action: .copy, sources: [],
                                          destination: OperationLocation(account: account, path: .unix(Data(destination.path.utf8))),
                                          sourceObservations: [], conflict: conflict)
        }

        func prepare() async throws -> OperationJournal.Ownership {
            let ownership = try await journal.acquireItem(id)
            _ = try journal.accept(intent, digest: "digest", ownership: ownership)
            try journal.recordWorkspace(workspace.record, ownership: ownership)
            let scratch = OperationRecoveryReference(identity: payload.observation.identity, purpose: .scratch,
                                                      original: nil, knownLocation: payload.location, possibleLocations: [payload.location])
            try journal.record(OperationReceipt(
                id: id, account: journal.account, epoch: journal.epoch, intentDigest: "digest", revision: 1,
                phase: .readyToCommit, outcome: .running, contentVerified: true, preparedPayload: payload, recovery: [scratch]
            ), ownership: ownership)
            return ownership
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
