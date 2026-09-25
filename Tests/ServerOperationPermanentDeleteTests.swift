import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationPermanentDeleteTests: XCTestCase {
    func testExplicitAcceptedDeletionRecordsEveryRemovedObjectWithoutFollowingLinks() async throws {
        for kind in [OperationObservation.Kind.file, .directory, .symbolicLink] {
            let fixture = try await Fixture(kind: kind)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let result = try await fixture.service.execute(fixture.identity)
            XCTAssertEqual(result.outcome, .committed)
            XCTAssertEqual(result.sourceDisposition, .confirmed)
            XCTAssertEqual(result.effects.count, fixture.manifest.entries.count)
            XCTAssertEqual(Set(result.effects.map(\.observation.identity)), Set(fixture.manifest.entries.map(\.observation.identity)))
            XCTAssertTrue(result.recovery.isEmpty)
            XCTAssertNil(result.failure)
            XCTAssertEqual(try fixture.parent.lookup(Data("source".utf8)), .missing)
            XCTAssertEqual(try Data(contentsOf: fixture.outside), fixture.bytes)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)), ["outside", "journal"])
            try Data("new occupant".utf8).write(to: fixture.source)
            let duplicate = try await fixture.service.execute(fixture.identity)
            XCTAssertEqual(duplicate, result)
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("new occupant".utf8))
        }
    }

    func testChangedAcceptedSourceAndEarlyCancellationLeaveEveryFile() async throws {
        for cancel in [false, true] {
            let fixture = try await Fixture(kind: .directory)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            if cancel {
                try fixture.service.cancel(fixture.identity)
            } else {
                try Data("changed".utf8).write(to: fixture.source.appendingPathComponent("nested/file"))
            }
            let before = try fixture.parent.manifest(Data("source".utf8), progress: { _ in })
            let result = try await fixture.service.execute(fixture.identity)
            XCTAssertEqual(result.outcome, .failedUnchanged)
            XCTAssertTrue(result.effects.isEmpty)
            XCTAssertTrue(result.recovery.isEmpty)
            XCTAssertEqual(try fixture.parent.manifest(Data("source".utf8), progress: { _ in }), before)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)), ["outside", "journal", "source"])
            let duplicate = try await fixture.service.execute(fixture.identity)
            XCTAssertEqual(duplicate, result)
        }
    }

    func testLostDeletionReceiptStaysUnknownAndNeverDeletesANewOccupant() async throws {
        let fixture = try await Fixture(kind: .file)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let workspace: OperationWorkspace
        let held: OperationLocation
        do {
            let ownership = try await fixture.service.journal.acquireItem(fixture.identity.id)
            let commit = try await fixture.service.journal.acquireCommit()
            defer { withExtendedLifetime((ownership, commit)) {} }
            workspace = try OperationWorkspace(parent: fixture.parent, id: fixture.identity.id)
            try fixture.service.journal.recordWorkspace(workspace.record, ownership: ownership)
            let expected = try XCTUnwrap(fixture.manifest.entries.first?.observation)
            let moved = try fixture.parent.moveExclusive(Data("source".utf8), to: workspace.directory,
                                                        named: Data("selected".utf8), expected: expected)
            held = .init(account: fixture.identity.account, path: .unix(try workspace.directory.childPath(Data("selected".utf8))))
            try fixture.service.journal.record(OperationReceipt(
                id: fixture.identity.id, account: fixture.identity.account, epoch: fixture.identity.epoch,
                intentDigest: fixture.identity.intentDigest, revision: 1, phase: .committing, outcome: .running,
                sourceDisposition: .unknown, plannedPaths: [held], recovery: [
                    .init(identity: moved.identity, purpose: .source, original: fixture.intent.sources[0],
                          knownLocation: held, possibleLocations: [held]),
                ]
            ), ownership: ownership)
            try workspace.directory.deleteImmediately(Data("selected".utf8), expected: moved)
        }
        try Data("new occupant".utf8).write(to: fixture.source)
        let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertTrue(result.effects.isEmpty)
        XCTAssertNil(result.recovery.first?.knownLocation)
        XCTAssertEqual(result.recovery.first?.possibleLocations, [held])
        let duplicate = try await fixture.service.execute(fixture.identity)
        XCTAssertEqual(duplicate, result)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("new occupant".utf8))
        XCTAssertEqual(try workspace.directory.names(), [])
    }

    func testPermanentDeletePrimitiveRefusesChangedFilesAndNonemptyDirectories() async throws {
        let fixture = try await Fixture(kind: .file)
        defer { fixture.cleanup() }
        let expected = try fixture.parent.observe(Data("source".utf8))
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("saved"))
        try Data("replacement".utf8).write(to: fixture.source)
        XCTAssertThrowsError(try fixture.parent.deleteImmediately(Data("source".utf8), expected: expected)) {
            XCTAssertEqual($0 as? OperationFilesystemError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("replacement".utf8))
        let directory = fixture.root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let empty = try fixture.parent.observe(Data("directory".utf8))
        let child = directory.appendingPathComponent("unexpected")
        try fixture.bytes.write(to: child)
        XCTAssertThrowsError(try fixture.parent.deleteImmediately(Data("directory".utf8), expected: empty))
        XCTAssertEqual(try Data(contentsOf: child), fixture.bytes)
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let outside: URL
        let parent: OperationDirectory
        let service: ServerOperationService
        let intent: OperationIntent
        let identity: OperationRequestIdentity
        let manifest: OperationManifest
        let bytes = Data("keep outside".utf8)

        init(kind: OperationObservation.Kind) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            source = root.appendingPathComponent("source")
            outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: outside)
            switch kind {
            case .file: try bytes.write(to: source)
            case .symbolicLink: try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: outside.path)
            case .directory:
                try FileManager.default.createDirectory(at: source.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
                try bytes.write(to: source.appendingPathComponent("nested/file"))
                try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("outside-link").path,
                                                          withDestinationPath: outside.path)
                try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("loop").path, withDestinationPath: ".")
            }
            parent = try OperationDirectory(path: Data(root.path.utf8))
            manifest = try parent.manifest(Data("source".utf8), progress: { _ in })
            let observed = try XCTUnwrap(manifest.entries.first?.observation)
            let expected = OperationObservation(identity: observed.identity, kind: observed.kind, version: observed.version,
                                                byteCount: observed.byteCount,
                                                sha256: kind == .file ? observed.sha256 : manifest.proof.sha256,
                                                linkTarget: observed.linkTarget, contentVersion: observed.contentVersion)
            let account = OperationAccount(hostIdentity: "fixture", accountIdentity: "fixture-user")
            service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account, homeDirectory: root)
            intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .permanentDelete,
                                     sources: [.init(account: account, path: .unix(Data(source.path.utf8)))],
                                     destination: nil, sourceObservations: [expected], conflict: .createNew)
            identity = OperationRequestIdentity(id: intent.id, account: account, epoch: service.journal.epoch,
                                                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
