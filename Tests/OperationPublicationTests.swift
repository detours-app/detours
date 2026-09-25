import Foundation
import RemoteOperationSupport
import XCTest

final class OperationPublicationTests: XCTestCase {
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

        init() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.root = root
            self.destination = root.appendingPathComponent("final")
            let account = OperationAccount(hostIdentity: "fixture-host", accountIdentity: "fixture-account")
            self.journal = try await OperationJournal(root: root.appendingPathComponent("journal"), account: account)
            let directory = try OperationDirectory(path: Data(root.path.utf8))
            let workspace = try OperationWorkspace(parent: directory, id: id)
            self.workspace = workspace
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
                                          sourceObservations: [], conflict: .createNew)
        }

        func prepare() async throws -> OperationJournal.Ownership {
            let ownership = try await journal.acquireItem(id)
            _ = try journal.accept(intent, digest: "digest", ownership: ownership)
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
