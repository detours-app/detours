import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationBackupTests: XCTestCase {
    func testLostBackupHandoffResultIsLocatedWithoutRepeatingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = try fixture.url(fixture.original)
        try Data("original".utf8).write(to: destination)
        let incoming = Data("incoming".utf8)
        let service = try await fixture.service()
        let (request, intent) = try fixture.replacement(epoch: service.journal.epoch, contents: incoming)
        _ = try await service.accept(request, intent: intent)
        _ = try await service.prepareUpload(request, contents: incoming)
        let reservation = try fixture.store.plan(id: request.id, original: fixture.original)
        do {
            let ownership = try await service.journal.acquireItem(request.id)
            defer { withExtendedLifetime(ownership) {} }
            let published = try await OperationPublication.publish(journal: service.journal, id: request.id, ownership: ownership)
            let commit = try await service.journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            let original = try XCTUnwrap(published.recovery.first { $0.purpose == .displacedOriginal })
            let holding = try XCTUnwrap(original.knownLocation)
            let information = try fixture.store.prepare(reservation)
            let recovery = published.recovery.filter { $0 != original } + [
                OperationRecoveryReference(identity: original.identity, purpose: .displacedOriginal, original: fixture.original,
                                           knownLocation: nil, possibleLocations: [holding, reservation.item]),
                OperationRecoveryReference(identity: information.observation.identity, purpose: .scratch, original: nil,
                                           knownLocation: information.location, possibleLocations: [information.location]),
            ]
            try service.journal.record(OperationReceipt(
                id: request.id, account: request.account, epoch: request.epoch, intentDigest: request.intentDigest,
                revision: published.revision + 1, phase: .committed, outcome: .committed, effects: published.effects,
                sourceDisposition: published.sourceDisposition, contentVerified: true,
                plannedPaths: [reservation.item, reservation.information], recovery: recovery
            ), ownership: ownership)
            let held = try service.resolve(holding)
            let target = try service.resolve(reservation.item)
            _ = try held.directory.moveExclusive(held.name, to: target.directory, named: target.name,
                                                 expected: held.directory.observe(held.name))
        }
        let result = try XCTUnwrap(service.status(request).receipt)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.recovery.first { $0.purpose == .displacedOriginal }?.knownLocation, reservation.item)
        XCTAssertEqual(result.plannedPaths, [reservation.item, reservation.information])
        XCTAssertEqual(try Data(contentsOf: destination), incoming)
        XCTAssertEqual(try Data(contentsOf: fixture.url(reservation.item)), Data("original".utf8))
        let duplicate = try await service.commit(request)
        XCTAssertEqual(duplicate, result)
    }

    func testReplacementBackupHandoffPreservesTheCommittedDestination() async throws {
        for blocked in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let destination = try fixture.url(fixture.original)
            try Data("displaced original".utf8).write(to: destination)
            let service = try await fixture.service()
            let incoming = Data("new destination".utf8)
            let (request, intent) = try fixture.replacement(epoch: service.journal.epoch, contents: incoming)
            _ = try await service.accept(request, intent: intent)
            _ = try await service.prepareUpload(request, contents: incoming)
            if blocked {
                let trash = fixture.root.appendingPathComponent(".local/share/Trash")
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            }
            let result = try await service.commit(request)
            XCTAssertEqual(result.outcome, .committed)
            XCTAssertEqual(try Data(contentsOf: destination), incoming)
            let backup = try XCTUnwrap(result.recovery.first { $0.purpose == .displacedOriginal })
            XCTAssertEqual(backup.original, fixture.original)
            let held = try fixture.url(XCTUnwrap(backup.knownLocation))
            XCTAssertEqual(try Data(contentsOf: held), Data("displaced original".utf8))
            if blocked {
                XCTAssertNotNil(result.failure)
                XCTAssertTrue(held.path.contains(".detours-partial-"))
            } else {
                XCTAssertNil(result.failure)
                XCTAssertTrue(held.path.contains("/.local/share/Trash/files/"))
                let info = try fixture.url(XCTUnwrap(result.plannedPaths?.last))
                let text = try String(contentsOf: info, encoding: .utf8)
                XCTAssertTrue(text.contains("Path=\(destination.path)\n"))
                XCTAssertFalse(text.contains(".detours-partial-"))
                let snapshot = try service.status(request)
                let workspace = try XCTUnwrap(snapshot.workspace)
                let name = try XCTUnwrap(String(data: workspace.root.name, encoding: .utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path))
            }
            let duplicate = try await service.commit(request)
            XCTAssertEqual(duplicate, result)
        }
    }

    func testRestoreRetainedReplacementFromTrashOrHoldingWithoutOverwriting() async throws {
        for blocked in [false, true] {
            for changed in [false, true] {
                let fixture = try Fixture()
                defer { fixture.cleanup() }
                let destination = try fixture.url(fixture.original)
                let original = Data("original contents".utf8)
                let incoming = Data("incoming contents".utf8)
                try original.write(to: destination)
                let service = try await fixture.service()
                let (publication, replacement) = try fixture.replacement(epoch: service.journal.epoch, contents: incoming)
                _ = try await service.accept(publication, intent: replacement)
                _ = try await service.prepareUpload(publication, contents: incoming)
                if blocked {
                    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(".local/share/Trash"),
                                                            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                }
                let published = try await service.commit(publication)
                let retained = try XCTUnwrap(published.recovery.first { $0.purpose == .displacedOriginal })
                let source = try XCTUnwrap(retained.knownLocation)
                let held = try fixture.url(source)
                let (occupiedRequest, occupiedIntent) = try fixture.restore(published, retained: retained)
                _ = try await service.accept(occupiedRequest, intent: occupiedIntent)
                let occupied = try await service.execute(occupiedRequest)
                XCTAssertEqual(occupied.outcome, .failedUnchanged)
                XCTAssertEqual(try Data(contentsOf: destination), incoming)
                XCTAssertEqual(try Data(contentsOf: held), original)
                let preserved = fixture.root.appendingPathComponent("preserved-incoming")
                try FileManager.default.moveItem(at: destination, to: preserved)
                if changed { try Data("changed original".utf8).write(to: held) }
                let (request, intent) = try fixture.restore(published, retained: retained)
                _ = try await service.accept(request, intent: intent)
                let restored = try await service.execute(request)
                XCTAssertEqual(restored.outcome, changed ? .failedUnchanged : .committed)
                if changed {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                    XCTAssertEqual(try Data(contentsOf: held), Data("changed original".utf8))
                } else {
                    XCTAssertNil(restored.failure)
                    XCTAssertEqual(try Data(contentsOf: destination), original)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: held.path))
                    let previous = try XCTUnwrap(service.status(publication).receipt)
                    XCTAssertTrue(previous.recovery.isEmpty)
                    XCTAssertEqual(previous.effects, published.effects)
                    XCTAssertEqual(previous.outcome, .committed)
                    let workspace = try XCTUnwrap(service.status(publication).workspace)
                    let name = try XCTUnwrap(String(data: workspace.root.name, encoding: .utf8))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path))
                }
                XCTAssertEqual(try Data(contentsOf: preserved), incoming)
                let repeated = try await service.execute(request)
                XCTAssertEqual(repeated, restored)
            }
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

        func replacement(epoch: UUID, contents: Data) throws -> (OperationRequestIdentity, OperationIntent) {
            let observed = try OperationDirectory(path: Data(root.path.utf8)).observe(Data("source".utf8))
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy, sources: [],
                                         destination: original, sourceObservations: [], conflict: .replace(observed),
                                         payloadProof: try OperationContentProof.data(contents))
            return (OperationRequestIdentity(id: intent.id, account: account, epoch: epoch,
                                              intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256), intent)
        }

        func restore(_ receipt: OperationReceipt, retained: OperationRecoveryReference) throws -> (OperationRequestIdentity, OperationIntent) {
            let source = try XCTUnwrap(retained.knownLocation)
            let location = try url(source)
            let directory = try OperationDirectory(path: Data(location.deletingLastPathComponent().path.utf8))
            let observed = try directory.proveFile(Data(location.lastPathComponent.utf8), progress: { _ in })
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .restore, sources: [source],
                                         destination: retained.original, sourceObservations: [observed], conflict: .createNew,
                                         reverses: receipt.id)
            return (OperationRequestIdentity(id: intent.id, account: account, epoch: receipt.epoch,
                                              intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256), intent)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
