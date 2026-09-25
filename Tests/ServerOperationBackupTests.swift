import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationBackupTests: XCTestCase {
    func testLostBackupHandoffResultIsLocatedWithoutRepeatingIt() async throws {
        for action in [OperationIntent.Action.copy, .move] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let destination = try fixture.url(fixture.original)
            try Data("original".utf8).write(to: destination)
            let incoming = Data("incoming".utf8)
            let service = try await fixture.service()
            let (request, intent) = try fixture.replacement(epoch: service.journal.epoch, contents: incoming, action: action)
            _ = try await service.accept(request, intent: intent)
            if action == .move {
                _ = try await service.prepareCopy(request)
            } else {
                _ = try await service.prepareUpload(request, contents: incoming)
            }
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
                    revision: published.revision + 1, phase: .committed, outcome: published.outcome, effects: published.effects,
                    sourceDisposition: published.sourceDisposition, contentVerified: true,
                    plannedPaths: [reservation.item, reservation.information], recovery: recovery
                ), ownership: ownership)
                let held = try service.resolve(holding)
                let target = try service.resolve(reservation.item)
                _ = try held.directory.moveExclusive(held.name, to: target.directory, named: target.name,
                                                     expected: held.directory.observe(held.name))
            }
            let result = try XCTUnwrap(service.status(request).receipt)
            XCTAssertEqual(result.outcome, action == .move ? .running : .committed)
            XCTAssertEqual(result.phase, .committed)
            if action == .move {
                XCTAssertEqual(result.sourceDisposition, .present)
                XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("incoming")), incoming)
            }
            XCTAssertEqual(result.recovery.first { $0.purpose == .displacedOriginal }?.knownLocation, reservation.item)
            XCTAssertEqual(result.plannedPaths, [reservation.item, reservation.information])
            XCTAssertEqual(try Data(contentsOf: destination), incoming)
            XCTAssertEqual(try Data(contentsOf: fixture.url(reservation.item)), Data("original".utf8))
            let duplicate = try await service.commit(request)
            XCTAssertEqual(duplicate, result)
        }
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

    func testNativeReplacementRetainsOriginalAndConfirmsSourceDisposition() async throws {
        for action in [OperationIntent.Action.rename, .move] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let destination = try fixture.url(fixture.original)
            try Data("old destination".utf8).write(to: destination)
            let service = try await fixture.service()
            let incoming = Data("native source".utf8)
            let (request, intent) = try fixture.replacement(epoch: service.journal.epoch, contents: incoming, action: action)
            _ = try await service.accept(request, intent: intent)
            let result = try await service.execute(request)
            XCTAssertEqual(result.outcome, .committed)
            XCTAssertEqual(result.sourceDisposition, .confirmed)
            XCTAssertTrue(result.contentVerified)
            XCTAssertEqual(result.effects.first?.observation.identity, intent.sourceObservations.first?.identity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("incoming").path))
            XCTAssertEqual(try Data(contentsOf: destination), incoming)
            let retained = try XCTUnwrap(result.recovery.first { $0.purpose == .displacedOriginal })
            XCTAssertEqual(try Data(contentsOf: fixture.url(XCTUnwrap(retained.knownLocation))), Data("old destination".utf8))
            XCTAssertFalse(result.recovery.contains { $0.purpose == .source })
            let duplicate = try await service.execute(request)
            XCTAssertEqual(duplicate, result)
        }
    }

    func testNativeReplacementPreservesSelectedLinksAndDirectories() async throws {
        for kind in [OperationObservation.Kind.symbolicLink, .directory] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let destination = try fixture.url(fixture.original)
            let source = fixture.root.appendingPathComponent("incoming")
            let linkTarget = fixture.root.appendingPathComponent("link-target")
            try Data("original".utf8).write(to: destination)
            try Data("link target remains".utf8).write(to: linkTarget)
            if kind == .symbolicLink {
                try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: linkTarget.path)
            } else {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                try Data("nested contents".utf8).write(to: source.appendingPathComponent("child"))
            }
            let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
            let observed = try parent.proveObject(Data("incoming".utf8), progress: { _ in })
            let approved = try parent.observe(Data("source".utf8))
            let service = try await fixture.service()
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .move,
                                         sources: [.init(account: fixture.account, path: .unix(Data(source.path.utf8)))],
                                         destination: fixture.original, sourceObservations: [observed], conflict: .replace(approved))
            let request = OperationRequestIdentity(id: intent.id, account: fixture.account, epoch: service.journal.epoch,
                                                   intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await service.accept(request, intent: intent)
            let result = try await service.execute(request)
            XCTAssertEqual(result.outcome, .committed)
            XCTAssertEqual(result.sourceDisposition, .confirmed)
            XCTAssertTrue(result.contentVerified)
            XCTAssertEqual(result.effects.first?.observation.identity, observed.identity)
            XCTAssertEqual(result.effects.first?.observation.kind, kind)
            XCTAssertEqual(try parent.lookup(Data("incoming".utf8)), .missing)
            if kind == .symbolicLink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), linkTarget.path)
            } else {
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("child")), Data("nested contents".utf8))
            }
            XCTAssertEqual(try Data(contentsOf: linkTarget), Data("link target remains".utf8))
            let original = try XCTUnwrap(result.recovery.first { $0.purpose == .displacedOriginal }?.knownLocation)
            XCTAssertEqual(try Data(contentsOf: fixture.url(original)), Data("original".utf8))
        }
    }

    func testNativeReplacementRejectsChangedSourceDestinationAndCancellation() async throws {
        for failure in ["source", "destination", "cancel"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let destination = try fixture.url(fixture.original)
            let source = fixture.root.appendingPathComponent("incoming")
            try Data("old destination".utf8).write(to: destination)
            let service = try await fixture.service()
            let (request, intent) = try fixture.replacement(epoch: service.journal.epoch, contents: Data("source".utf8), action: .move)
            _ = try await service.accept(request, intent: intent)
            if failure == "source" { try Data("changed source".utf8).write(to: source) }
            if failure == "destination" { try Data("changed destination".utf8).write(to: destination) }
            if failure == "cancel" { try service.cancel(request) }
            do {
                _ = try await service.execute(request)
                XCTFail("Native replacement accepted a changed or cancelled intent")
            } catch {
                XCTAssertTrue(error is OperationFilesystemError || error is OperationContractError)
            }
            XCTAssertEqual(try Data(contentsOf: source), Data((failure == "source" ? "changed source" : "source").utf8))
            XCTAssertEqual(try Data(contentsOf: destination), Data((failure == "destination" ? "changed destination" : "old destination").utf8))
            let result = try service.status(request)
            XCTAssertFalse(result.receipt?.outcome == .committed)
            XCTAssertFalse(result.receipt?.recovery.contains { $0.purpose == .displacedOriginal } ?? false)
            XCTAssertEqual(result.receipt?.outcome, .failedUnchanged)
            let repeated = try await service.execute(request)
            XCTAssertEqual(repeated, result.receipt)
            XCTAssertTrue(repeated.recovery.isEmpty)
        }
    }

    func testNativeReplacementRejectsChangedNestedContentWithUnchangedRootVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("incoming")
        let destination = try fixture.url(fixture.original)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("original child".utf8).write(to: source.appendingPathComponent("child"))
        try Data("old destination".utf8).write(to: destination)
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        let expected = try parent.proveObject(Data("incoming".utf8), progress: { _ in })
        let approved = try parent.observe(Data("source".utf8))
        let service = try await fixture.service()
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .move,
                                     sources: [.init(account: fixture.account, path: .unix(Data(source.path.utf8)))],
                                     destination: fixture.original, sourceObservations: [expected], conflict: .replace(approved))
        let request = OperationRequestIdentity(id: intent.id, account: fixture.account, epoch: service.journal.epoch,
                                               intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        _ = try await service.accept(request, intent: intent)
        try Data("changed child".utf8).write(to: source.appendingPathComponent("child"))
        XCTAssertEqual(try parent.observe(Data("incoming".utf8)).version, expected.version)
        do {
            _ = try await service.execute(request)
            XCTFail("Nested content changed without being refused")
        } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
        XCTAssertEqual(try service.status(request).receipt?.outcome, .failedUnchanged)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old destination".utf8))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("child")), Data("changed child".utf8))
    }

    func testLostDirectoryMoveReceiptUsesManifestEvidenceWithoutReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: source.appendingPathComponent("child"))
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        let expected = try parent.proveObject(Data("incoming".utf8), progress: { _ in })
        let location = OperationLocation(account: fixture.account, path: .unix(Data(source.path.utf8)))
        let service = try await fixture.service()
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .move, sources: [location],
                                     destination: fixture.original, sourceObservations: [expected], conflict: .createNew)
        let request = OperationRequestIdentity(id: intent.id, account: fixture.account, epoch: service.journal.epoch,
                                               intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        _ = try await service.accept(request, intent: intent)
        do {
            let ownership = try await service.journal.acquireItem(intent.id)
            defer { withExtendedLifetime(ownership) {} }
            try service.journal.record(OperationReceipt(
                id: intent.id, account: fixture.account, epoch: request.epoch, intentDigest: request.intentDigest,
                revision: 1, phase: .committing, outcome: .running, sourceDisposition: .unknown,
                preparedPayload: OperationEffect(location: location, observation: expected), recovery: [
                    .init(identity: expected.identity, purpose: .source, original: location, knownLocation: nil,
                          possibleLocations: [location, fixture.original]),
                ]
            ), ownership: ownership)
            _ = try parent.moveExclusive(Data("incoming".utf8), to: parent, named: Data("source".utf8), expected: expected)
        }
        let result = try XCTUnwrap(service.status(request).receipt)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.sourceDisposition, .confirmed)
        XCTAssertTrue(result.contentVerified)
        XCTAssertEqual(result.effects.first?.observation.sha256, expected.sha256)
        let duplicate = try await service.execute(request)
        XCTAssertEqual(duplicate, result)
        XCTAssertEqual(try Data(contentsOf: fixture.url(fixture.original).appendingPathComponent("child")), Data("nested".utf8))
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

        func replacement(epoch: UUID, contents: Data, action: OperationIntent.Action = .copy) throws -> (OperationRequestIdentity, OperationIntent) {
            let observed = try OperationDirectory(path: Data(root.path.utf8)).observe(Data("source".utf8))
            var sources: [OperationLocation] = []
            var observations: [OperationObservation] = []
            if action != .copy {
                let source = root.appendingPathComponent("incoming")
                try contents.write(to: source)
                sources = [OperationLocation(account: account, path: .unix(Data(source.path.utf8)))]
                observations = [try OperationDirectory(path: Data(root.path.utf8)).proveFile(Data("incoming".utf8), progress: { _ in })]
            }
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: action, sources: sources,
                                         destination: original, sourceObservations: observations, conflict: .replace(observed),
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
