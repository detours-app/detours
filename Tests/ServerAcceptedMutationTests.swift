import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerAcceptedMutationTests: XCTestCase {
    func testAcceptedPermanentDeleteRemovesOnlyTheSelectedFileWithoutTrashMetadata() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("selected")
        try Data("body".utf8).write(to: source)
        let request = try await fixture.accept(.permanentDelete, source: source)
        let result = try await fixture.service.execute(request)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.sourceDisposition, .confirmed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["journal"])
    }

    func testAcceptedCopyUsesTheChosenSiblingNameWithoutAnRPCPayloadLimit() async throws {
        for size in [4, 1_048_577] {
            let fixture = try await Fixture()
            defer { fixture.cleanup() }
            let bytes = Data(repeating: 7, count: size)
            let source = fixture.root.appendingPathComponent("source.txt")
            let destination = fixture.root.appendingPathComponent("source copy.txt")
            try bytes.write(to: source)
            let request = try await fixture.accept(.copy, source: source, destination: destination)
            let ready = try await fixture.service.prepareCopy(request)
            XCTAssertEqual(ready.phase, .readyToCommit)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let result = try await fixture.service.commit(request)
            XCTAssertEqual(result.outcome, .committed)
            XCTAssertEqual(result.effects.first?.location, fixture.location(destination))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }
    }

    func testAcceptedMoveOntoItsSourceRefusesWithoutChangingIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source.txt")
        let bytes = Data("body".utf8)
        try bytes.write(to: source)
        let request = try await fixture.accept(.move, source: source, destination: source)
        let result = try await fixture.service.execute(request)
        XCTAssertEqual(result.outcome, .failedUnchanged)
        XCTAssertTrue(result.effects.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let repeated = try await fixture.service.execute(request)
        XCTAssertEqual(repeated, result)
    }

    func testAcceptedUploadRenameTrashAndRestoreRetainContentAndReceipts() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let uploaded = fixture.root.appendingPathComponent("uploaded.txt")
        let renamed = fixture.root.appendingPathComponent("renamed.txt")
        let bytes = Data("upload".utf8)
        let upload = try await fixture.accept(.editorUpload, destination: uploaded, bytes: bytes)
        let ready = try await fixture.service.prepareUpload(upload, contents: bytes)
        XCTAssertEqual(ready.phase, .readyToCommit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploaded.path))
        let committed = try await fixture.service.commit(upload)
        XCTAssertEqual(committed.outcome, .committed)
        XCTAssertEqual(try FileOperations().download(path: ServerRemotePath(uploaded.path), maximumRPCBytes: 1_024), bytes)

        let rename = try await fixture.accept(.rename, source: uploaded, destination: renamed)
        let moved = try await fixture.service.execute(rename)
        XCTAssertEqual(moved.outcome, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploaded.path))
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)

        let trash = try await fixture.accept(.trash, source: renamed)
        let trashed = try await fixture.service.execute(trash)
        XCTAssertEqual(trashed.outcome, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        let effect = try XCTUnwrap(trashed.effects.first)
        guard case .unix(let path) = effect.location.path else { return XCTFail("Expected a Unix Trash path") }
        let retained = URL(fileURLWithPath: try XCTUnwrap(String(data: path, encoding: .utf8)))
        XCTAssertEqual(try Data(contentsOf: retained), bytes)

        let restore = try await fixture.accept(.restore, source: retained, destination: renamed, reverses: trashed.id)
        let restored = try await fixture.service.execute(restore)
        XCTAssertEqual(restored.outcome, .committed)
        XCTAssertEqual(restored.effects.first?.location, fixture.location(renamed))
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(try fixture.service.status(trash).receipt?.recovery, [])
        let repeated = try await fixture.service.execute(restore)
        XCTAssertEqual(repeated, restored)
    }

    private struct Fixture {
        let root: URL
        let service: ServerOperationService

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            service = try await ServerOperationService(root: root.appendingPathComponent("journal"),
                account: .init(hostIdentity: "fixture", accountIdentity: "fixture-user"), homeDirectory: root)
        }

        func location(_ url: URL) -> OperationLocation {
            .init(account: service.journal.account, path: .unix(Data(url.path.utf8)))
        }

        func accept(_ action: OperationIntent.Action, source: URL? = nil, destination: URL? = nil,
                    bytes: Data? = nil, reverses: OperationItemID? = nil) async throws -> OperationRequestIdentity {
            let observations: [OperationObservation]
            if let source {
                let parent = try OperationDirectory(path: Data(source.deletingLastPathComponent().path.utf8))
                observations = [try parent.proveFile(Data(source.lastPathComponent.utf8), progress: { _ in })]
            } else { observations = [] }
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: action,
                sources: source.map { [location($0)] } ?? [], destination: destination.map(location),
                sourceObservations: observations, conflict: .createNew, reverses: reverses,
                payloadProof: try bytes.map(OperationContentProof.data))
            let request = OperationRequestIdentity(id: intent.id, account: service.journal.account, epoch: service.journal.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await service.accept(request, intent: intent)
            return request
        }

        func cleanup() { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
    }
}
