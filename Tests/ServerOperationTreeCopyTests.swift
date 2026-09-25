import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationTreeCopyTests: XCTestCase {
    func testCompleteTreeIsPreparedPrivatelyThenPublishedOnce() async throws {
        for action in [OperationIntent.Action.copy, .move] {
            let fixture = try await Fixture(action: action)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let ready = try await fixture.service.prepareCopy(fixture.identity)
            XCTAssertEqual(ready.phase, .readyToCommit)
            XCTAssertTrue(ready.contentVerified)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            let snapshot = try fixture.service.status(fixture.identity)
            XCTAssertEqual(snapshot.sourceManifest, fixture.original)
            XCTAssertEqual(snapshot.payloadManifest?.proof, fixture.original.proof)
            XCTAssertEqual(try fixture.manifest("source"), fixture.original)
            let committed = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(committed.outcome, action == .move ? .running : .committed)
            XCTAssertEqual(committed.sourceDisposition, action == .move ? .present : .notRequired)
            XCTAssertEqual(committed.effects.count, 1)
            XCTAssertTrue(committed.recovery.isEmpty)
            XCTAssertNil(committed.failure)
            XCTAssertEqual(try fixture.manifest("destination").proof, fixture.original.proof)
            XCTAssertEqual(try fixture.manifest("source"), fixture.original)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.appendingPathComponent("nested/loop").path), "..")
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.destination.appendingPathComponent("nested").path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
            XCTAssertEqual(attributes[.modificationDate] as? Date, fixture.modified)
            let duplicate = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(duplicate, committed)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)), ["journal", "source", "destination"])
        }
    }

    func testSelectedDanglingLinkIsCopiedWithoutFollowingIt() async throws {
        let fixture = try await Fixture(link: true)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let ready = try await fixture.service.prepareCopy(fixture.identity)
        XCTAssertEqual(ready.preparedPayload?.observation.kind, .symbolicLink)
        let committed = try await fixture.service.commit(fixture.identity)
        XCTAssertEqual(committed.outcome, .committed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path), "missing target")
        XCTAssertEqual(try fixture.manifest("source"), fixture.original)
        XCTAssertEqual(try fixture.manifest("destination").proof, fixture.original.proof)
    }

    func testChangedNestedSourceRejectsAcceptedTreeProof() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        try Data("changed".utf8).write(to: fixture.source.appendingPathComponent("nested/file"))
        XCTAssertEqual(try fixture.manifest("source").entries.first?.observation.version, fixture.original.entries.first?.observation.version)
        do {
            _ = try await fixture.service.prepareCopy(fixture.identity)
            XCTFail("Changed tree was accepted")
        } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)), ["journal", "source"])
    }

    func testChangedNestedPayloadCannotBePublished() async throws {
        for replace in [false, true] {
            let fixture = try await Fixture()
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let ready = try await fixture.service.prepareCopy(fixture.identity)
            let payload = try fixture.url(XCTUnwrap(ready.preparedPayload).location)
            let file = payload.appendingPathComponent("nested/file")
            if replace {
                try FileManager.default.moveItem(at: file, to: fixture.root.appendingPathComponent("saved"))
                try Data("contents".utf8).write(to: file)
            } else {
                try Data("changed".utf8).write(to: file)
            }
            do {
                _ = try await fixture.service.commit(fixture.identity)
                XCTFail("Changed private tree was published")
            } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try fixture.manifest("source"), fixture.original)
            let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
            XCTAssertEqual(result.outcome, replace ? .partial : .failedUnchanged)
            if replace { XCTAssertEqual(try Data(contentsOf: file), Data("contents".utf8)) }
        }
    }

    func testCancellationAndDestinationCompetitionPreserveOriginals() async throws {
        for cancel in [false, true] {
            let fixture = try await Fixture()
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            _ = try await fixture.service.prepareCopy(fixture.identity)
            if cancel {
                try fixture.service.cancel(fixture.identity)
            } else {
                try Data("competitor".utf8).write(to: fixture.destination)
            }
            do {
                _ = try await fixture.service.commit(fixture.identity)
                XCTFail("Invalid publication succeeded")
            } catch {
                if cancel { XCTAssertEqual(error as? OperationContractError, .cancelled) }
            }
            XCTAssertEqual(try fixture.manifest("source"), fixture.original)
            if cancel {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("competitor".utf8))
            }
        }
    }

    func testCopyIntoSourceTreeFailsBeforeCreatingScratch() async throws {
        let fixture = try await Fixture(nestedDestination: true)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        do {
            _ = try await fixture.service.prepareCopy(fixture.identity)
            XCTFail("Source was used as its own temporary destination")
        } catch { XCTAssertEqual(error as? OperationFilesystemError, .unsupported) }
        XCTAssertEqual(try fixture.manifest("source"), fixture.original)
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
        XCTAssertNil(try fixture.service.status(fixture.identity).workspace)
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let service: ServerOperationService
        let intent: OperationIntent
        let identity: OperationRequestIdentity
        let original: OperationManifest
        let modified = Date(timeIntervalSince1970: 1_600_000_000)

        init(action: OperationIntent.Action = .copy, link: Bool = false, nestedDestination: Bool = false) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            source = root.appendingPathComponent("source")
            destination = nestedDestination ? source.appendingPathComponent("nested/destination") : root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if link {
                try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "missing target")
            } else {
                let nested = source.appendingPathComponent("nested")
                try FileManager.default.createDirectory(at: nested.appendingPathComponent("empty"), withIntermediateDirectories: true)
                try Data("contents".utf8).write(to: nested.appendingPathComponent("file"))
                try Data().write(to: source.appendingPathComponent("zero"))
                try FileManager.default.createSymbolicLink(atPath: nested.appendingPathComponent("loop").path, withDestinationPath: "..")
                try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("dangling").path, withDestinationPath: "absent")
                try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: modified], ofItemAtPath: nested.path)
            }
            let account = OperationAccount(hostIdentity: "fixture", accountIdentity: "fixture-user")
            service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account, homeDirectory: root)
            original = try OperationDirectory(path: Data(root.path.utf8)).manifest(Data("source".utf8), progress: { _ in })
            let observed = try XCTUnwrap(original.entries.first?.observation)
            let expected = OperationObservation(identity: observed.identity, kind: observed.kind, version: observed.version,
                                                byteCount: observed.byteCount, sha256: original.proof.sha256,
                                                linkTarget: observed.linkTarget, contentVersion: observed.contentVersion)
            intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: action,
                                     sources: [.init(account: account, path: .unix(Data(source.path.utf8)))],
                                     destination: .init(account: account, path: .unix(Data(destination.path.utf8))),
                                     sourceObservations: [expected], conflict: .createNew, payloadProof: original.proof)
            identity = OperationRequestIdentity(id: intent.id, account: account, epoch: service.journal.epoch,
                                                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }

        func manifest(_ name: String) throws -> OperationManifest {
            try OperationDirectory(path: Data(root.path.utf8)).manifest(Data(name.utf8), progress: { _ in })
        }

        func url(_ location: OperationLocation) throws -> URL {
            guard case .unix(let bytes) = location.path else { throw OperationFilesystemError.invalidPath }
            return URL(fileURLWithPath: try XCTUnwrap(String(data: bytes, encoding: .utf8)))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
