import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationTrashTests: XCTestCase {
    func testLostTrashResultIsReconciledWithoutRepeatingTheMove() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.url(fixture.original)
        let bytes = Data("preserved source".utf8)
        try bytes.write(to: source)
        let service = try await fixture.service()
        let (request, intent) = try fixture.intent(epoch: service.journal.epoch)
        _ = try await service.accept(request, intent: intent)
        let reservation = try fixture.store.plan(id: request.id, original: fixture.original)
        do {
            let ownership = try await service.journal.acquireItem(request.id)
            let commit = try await service.journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            let information = try fixture.store.prepare(reservation)
            let expected = try XCTUnwrap(intent.sourceObservations.first)
            try service.journal.record(OperationReceipt(
                id: request.id, account: request.account, epoch: request.epoch, intentDigest: request.intentDigest,
                revision: 1, phase: .committing, outcome: .running, sourceDisposition: .unknown,
                preparedPayload: OperationEffect(location: fixture.original, observation: expected),
                plannedPaths: [reservation.item, reservation.information], recovery: [
                    OperationRecoveryReference(identity: expected.identity, purpose: .source, original: fixture.original,
                                               knownLocation: nil, possibleLocations: [fixture.original, reservation.item]),
                    OperationRecoveryReference(identity: information.observation.identity, purpose: .scratch, original: nil,
                                               knownLocation: information.location, possibleLocations: [information.location]),
                ]
            ), ownership: ownership)
            let target = try fixture.url(reservation.item)
            let origin = try OperationDirectory(path: Data(fixture.root.path.utf8))
            let destination = try OperationDirectory(path: Data(target.deletingLastPathComponent().path.utf8))
            _ = try origin.moveExclusive(Data("source".utf8), to: destination,
                                         named: Data(target.lastPathComponent.utf8), expected: expected)
            withExtendedLifetime(ownership) {}
        }
        let result = try XCTUnwrap(service.status(request).receipt)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.sourceDisposition, .confirmed)
        XCTAssertEqual(result.recovery.first { $0.purpose == .sourceTrash }?.knownLocation, reservation.item)
        XCTAssertEqual(result.plannedPaths, [reservation.item, reservation.information])
        XCTAssertEqual(try Data(contentsOf: fixture.url(reservation.item)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let duplicate = try await service.execute(request)
        XCTAssertEqual(duplicate, result)
    }

    func testJournaledTrashRetainsOneResultAndPreservesSelectedLinks() async throws {
        for link in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let source = try fixture.url(fixture.original)
            let target = fixture.root.appendingPathComponent("target")
            let bytes = Data("user content".utf8)
            if link {
                try bytes.write(to: target)
                try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: target.path)
            } else { try bytes.write(to: source) }
            let service = try await fixture.service()
            let (request, intent) = try fixture.intent(epoch: service.journal.epoch)
            _ = try await service.accept(request, intent: intent)
            let result = try await service.execute(request)
            XCTAssertEqual(result.outcome, .committed)
            XCTAssertEqual(result.sourceDisposition, .confirmed)
            let duplicate = try await service.execute(request)
            XCTAssertEqual(duplicate, result)
            let retained = try XCTUnwrap(result.recovery.first { $0.purpose == .sourceTrash })
            XCTAssertEqual(retained.original, fixture.original)
            let trash = try fixture.url(XCTUnwrap(retained.knownLocation))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            if link {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: trash.path), target.path)
                XCTAssertEqual(try Data(contentsOf: target), bytes)
            } else { XCTAssertEqual(try Data(contentsOf: trash), bytes) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.url(XCTUnwrap(result.plannedPaths?.last)).path))
        }
    }

    func testCancellationAndChangedSourceLeaveTrashUnprepared() async throws {
        for cancelled in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let source = try fixture.url(fixture.original)
            try Data("original".utf8).write(to: source)
            let service = try await fixture.service()
            let (request, intent) = try fixture.intent(epoch: service.journal.epoch)
            _ = try await service.accept(request, intent: intent)
            if cancelled { try service.cancel(request) } else { try Data("changed source".utf8).write(to: source) }
            let result = try await service.execute(request)
            XCTAssertEqual(result.outcome, .failedUnchanged)
            XCTAssertTrue(result.recovery.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".local").path))
        }
    }

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

        func service() async throws -> ServerOperationService {
            try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account, homeDirectory: root)
        }

        func intent(epoch: UUID) throws -> (OperationRequestIdentity, OperationIntent) {
            let directory = try OperationDirectory(path: Data(root.path.utf8))
            let observed = try directory.observe(Data("source".utf8))
            let observation = observed.kind == .file ? try directory.proveFile(Data("source".utf8), progress: { _ in }) : observed
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .trash, sources: [original],
                                         destination: nil, sourceObservations: [observation], conflict: .createNew)
            return (OperationRequestIdentity(id: intent.id, account: account, epoch: epoch,
                                              intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256), intent)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
