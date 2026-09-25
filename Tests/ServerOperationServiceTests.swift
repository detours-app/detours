import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationServiceTests: XCTestCase {
    func testAcceptedUploadsRequireSeparateCommitAndRetainOneResult() async throws {
        for size in [0, 1_048_575, 1_048_576] {
            let fixture = try await Fixture(size: size)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let prepared = try await fixture.service.prepareUpload(fixture.identity, contents: fixture.bytes)
            XCTAssertEqual(prepared.phase, .readyToCommit)
            XCTAssertEqual(prepared.preparedPayload?.observation.sha256, fixture.intent.payloadProof?.sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertNotNil(try fixture.service.status(fixture.identity).workspace)
            let committed = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(committed.outcome, .committed)
            XCTAssertEqual(committed.phase, .terminal)
            XCTAssertTrue(committed.recovery.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
            let duplicate = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(duplicate, committed)
            try await fixture.service.acknowledge(fixture.identity, retainingUndo: false)
            XCTAssertTrue(try fixture.service.status(fixture.identity).acknowledged)
        }
    }

    func testWrongByteCountOrHashLeavesDestinationUntouched() async throws {
        for bad in [Data([1]), Data(repeating: 7, count: 32)] {
            let fixture = try await Fixture(size: 32)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            do {
                _ = try await fixture.service.prepareUpload(fixture.identity, contents: bad)
                XCTFail("Mismatching bytes were accepted")
            } catch { XCTAssertEqual(error as? OperationContractError, .invalidReceipt) }
            XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["journal"])
        }
    }

    func testStatusAndCancellationDoNotNeedWorkerOwnership() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let ownership = try await fixture.service.journal.acquireItem(fixture.identity.id)
        XCTAssertNil(try fixture.service.status(fixture.identity).receipt)
        try fixture.service.cancel(fixture.identity)
        XCTAssertTrue(try fixture.service.journal.cancellationRequested(fixture.identity.id))
        withExtendedLifetime(ownership) {}
    }

    func testOpenWorkerRejectsResetJournalEpoch() async throws {
        let fixture = try await Fixture(size: 1)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let journalRoot = fixture.root.appendingPathComponent("journal")
        try FileManager.default.removeItem(at: journalRoot.appendingPathComponent("epoch.json"))
        _ = try await OperationJournal(root: journalRoot, account: fixture.identity.account)
        XCTAssertThrowsError(try fixture.service.status(fixture.identity)) {
            XCTAssertEqual($0 as? OperationContractError, .epochMismatch)
        }
        XCTAssertThrowsError(try fixture.service.cancel(fixture.identity))
    }

    func testOpenWorkerRejectsReplacedJournalDirectory() async throws {
        let fixture = try await Fixture(size: 1)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let journalRoot = fixture.root.appendingPathComponent("journal")
        try FileManager.default.moveItem(at: journalRoot, to: fixture.root.appendingPathComponent("old-journal"))
        let replacement = try await OperationJournal(root: journalRoot, account: fixture.identity.account)
        XCTAssertNotEqual(replacement.epoch, fixture.identity.epoch)
        XCTAssertThrowsError(try fixture.service.status(fixture.identity)) {
            XCTAssertEqual($0 as? OperationContractError, .epochMismatch)
        }
        XCTAssertThrowsError(try fixture.service.cancel(fixture.identity))
        do {
            _ = try await fixture.service.journal.acquireCommit()
            XCTFail("Replaced journal admitted an old worker")
        } catch { XCTAssertEqual(error as? OperationContractError, .epochMismatch) }
    }

    func testStatusProvesLostPublicationWithoutRepeatingOrCleaningIt() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let ready = try await fixture.service.prepareUpload(fixture.identity, contents: fixture.bytes)
        let payload = try XCTUnwrap(ready.preparedPayload)
        let uncertain = try await fixture.stageInterruptedPublication(ready)
        XCTAssertEqual(uncertain.phase, .committing)
        guard case .unix(let bytes) = payload.location.path else { return XCTFail("Expected Unix payload") }
        let payloadURL = URL(fileURLWithPath: try XCTUnwrap(String(data: bytes, encoding: .utf8)))
        let source = try OperationDirectory(path: Data(payloadURL.deletingLastPathComponent().path.utf8))
        let destination = try OperationDirectory(path: Data(fixture.root.path.utf8))
        _ = try source.moveExclusive(Data(payloadURL.lastPathComponent.utf8), to: destination,
                                     named: Data("destination".utf8), expected: payload.observation)
        let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.effects.first?.observation.identity, payload.observation.identity)
        XCTAssertEqual(result.recovery.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.deletingLastPathComponent().path))
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt, result)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
    }

    func testStatusKeepsIdenticalCompetingContentUnknownAndDoesNotResumeUpload() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let ready = try await fixture.service.prepareUpload(fixture.identity, contents: fixture.bytes)
        _ = try await fixture.stageInterruptedPublication(ready)
        try fixture.bytes.write(to: fixture.destination)
        let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertTrue(result.effects.isEmpty)
        XCTAssertEqual(result.recovery.count, ready.recovery.count)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertNotNil(try fixture.service.status(fixture.identity).workspace)
    }

    private struct Fixture {
        let root: URL
        let destination: URL
        let bytes: Data
        let service: ServerOperationService
        let identity: OperationRequestIdentity
        let intent: OperationIntent

        init(size: Int) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.root = root
            self.destination = root.appendingPathComponent("destination")
            self.bytes = Data(repeating: 42, count: size)
            let account = OperationAccount(hostIdentity: "fixture", accountIdentity: "fixture-user")
            let service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account)
            self.service = service
            let intent = OperationIntent(
                id: .init(operation: UUID(), item: UUID()), action: .copy, sources: [],
                destination: OperationLocation(account: account, path: .unix(Data(destination.path.utf8))),
                sourceObservations: [], conflict: .createNew, payloadProof: try OperationContentProof.data(bytes)
            )
            self.intent = intent
            self.identity = OperationRequestIdentity(id: intent.id, account: account, epoch: service.journal.epoch,
                                                      intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func stageInterruptedPublication(_ ready: OperationReceipt) async throws -> OperationReceipt {
            let ownership = try await service.journal.acquireItem(identity.id)
            let payload = try XCTUnwrap(ready.preparedPayload)
            let uncertain = OperationRecoveryReference(
                identity: payload.observation.identity, purpose: .scratch, original: nil, knownLocation: nil,
                possibleLocations: [payload.location, try XCTUnwrap(intent.destination)]
            )
            let receipt = OperationReceipt(
                id: identity.id, account: identity.account, epoch: identity.epoch, intentDigest: identity.intentDigest,
                revision: ready.revision + 1, phase: .committing, outcome: .running,
                contentVerified: true, preparedPayload: payload,
                recovery: ready.recovery.filter { $0.identity != payload.observation.identity } + [uncertain]
            )
            try service.journal.record(receipt, ownership: ownership)
            XCTAssertEqual(try service.status(identity).receipt, receipt)
            withExtendedLifetime(ownership) {}
            return receipt
        }
    }
}
