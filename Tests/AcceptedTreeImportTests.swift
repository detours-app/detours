import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

final class AcceptedTreeImportTests: XCTestCase {
    func testReceivedArchiveCannotPublishBeforeWholeTreeVerification() async throws {
        try await run(.prematureCommit)
    }

    func testWholeTreePublishesWithEmptyDirectoryAndRelativeLink() async throws {
        try await run(.success)
    }

    func testWrongTreeProofPreservesOriginalAndPublishesNothing() async throws {
        try await run(.wrongProof)
    }

    func testChangedLaterPreparedChildPreventsPublication() async throws {
        try await run(.changedChild)
    }

    func testEmptyTreePublishesAsDirectory() async throws {
        try await run(.empty)
    }

    private enum Scenario { case prematureCommit, success, wrongProof, changedChild, empty }

    private func run(_ scenario: Scenario) async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let folder = fixture.root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        if scenario != .empty {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: false)
            try fixture.bytes.write(to: folder.appendingPathComponent("a child"))
            try Data("later child".utf8).write(to: folder.appendingPathComponent("z child"))
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path,
                                                     withDestinationPath: "a child")
        }
        let archive = fixture.root.appendingPathComponent("tree.zip")
        guard FileManager.default.createFile(atPath: archive.path, contents: nil) else {
            throw OperationFilesystemError.unsupported
        }
        let output = try FileHandle(forWritingTo: archive)
        let manifest = try RemoteTransferArchive.write(folder: folder, output: output, progress: { _ in })
        try output.close()
        let bytes = try Data(contentsOf: archive)
        let service = fixture.boundary.service
        let intent = try OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy,
            sources: [.init(account: .init(hostIdentity: "origin", accountIdentity: "origin"), path: .unix(Data(folder.path.utf8)))],
            destination: .init(account: fixture.account, path: .unix(Data(fixture.destination.path.utf8))),
            sourceObservations: [XCTUnwrap(manifest.entries.first?.observation)], conflict: .createNew,
            payloadProof: .data(bytes), sourceManifest: manifest,
            treeProof: scenario == .wrongProof ? .data(Data("wrong tree".utf8)) : manifest.proof)
        let identity = OperationRequestIdentity(id: intent.id, account: fixture.account, epoch: service.journal.epoch,
            intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        _ = try await service.accept(identity, intent: intent)
        let received = try await service.prepareUpload(identity, contents: bytes)
        XCTAssertEqual(received.phase, .payloadReceived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try service.status(identity).receipt, received)
        if scenario == .prematureCommit {
            do { _ = try await service.commit(identity); XCTFail("Published the transport archive") } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path)) }
            return
        }
        if scenario == .wrongProof {
            do { _ = try await service.prepareImportedTree(identity); XCTFail("Accepted different tree content") } catch { XCTAssertEqual(try service.status(identity).receipt?.outcome, .failedUnchanged) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("z child")), Data("later child".utf8))
            return
        }
        let ready = try await service.prepareImportedTree(identity)
        XCTAssertEqual(ready.phase, .readyToCommit)
        XCTAssertEqual(ready.preparedPayload?.observation.kind, .directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let repeated = try await service.prepareImportedTree(identity)
        XCTAssertEqual(repeated, ready)
        if scenario == .changedChild {
            guard case .unix(let path) = try XCTUnwrap(ready.preparedPayload?.location.path),
                  let name = String(data: path, encoding: .utf8) else { return XCTFail("Missing tree path") }
            try Data("changed".utf8).write(to: URL(fileURLWithPath: name).appendingPathComponent("z child"))
            do { _ = try await service.commit(identity); XCTFail("Published a changed child") } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path)) }
        } else {
            let result = try await service.commit(identity)
            XCTAssertEqual(result.outcome, .committed)
            XCTAssertTrue(result.contentVerified)
            let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
            let actual = try parent.manifest(Data("destination".utf8), progress: { _ in })
            XCTAssertEqual(actual.proof, manifest.proof)
            if scenario == .success {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
                    atPath: fixture.destination.appendingPathComponent("link").path), "a child")
                XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent("z child")), Data("later child".utf8))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
}
