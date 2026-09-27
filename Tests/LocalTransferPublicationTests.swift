import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class LocalTransferPublicationTests: XCTestCase {
    func testLocalFolderRemainsPrivateUntilVerifiedCommit() async throws { try await run(.folder) }
    func testLocalFileUsesVerifiedNonReplacingCommit() async throws { try await run(.file) }
    func testCompetingLocalDestinationIsPreserved() async throws { try await run(.competingName) }
    func testChangedPreparedChildPreventsLocalPublication() async throws { try await run(.changedChild) }
    func testCancelledPreparationPreservesOriginalAndDestination() async throws { try await run(.cancelled) }
    func testApprovedLocalReplacementRetainsDisplacedOriginal() async throws { try await run(.replacement) }

    private enum Scenario { case folder, file, competingName, changedChild, cancelled, replacement }

    private func run(_ scenario: Scenario) async throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let source = root.appendingPathComponent("staged")
        let destination = root.appendingPathComponent("destination")
        if scenario == .file {
            try Data("file bytes".utf8).write(to: source)
        } else {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try Data("folder bytes".utf8).write(to: source.appendingPathComponent("child"))
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "child")
        }
        let parent = try OperationDirectory(path: Data(root.path.utf8))
        let manifest = try parent.manifest(Data("staged".utf8), progress: { _ in })
        let observed = try XCTUnwrap(manifest.entries.first?.observation)
        let account = OperationAccount(hostIdentity: "local-fixture", accountIdentity: "local-fixture")
        let journal = try await OperationJournal(root: root.appendingPathComponent("journal"), account: account)
        let conflict: OperationIntent.Conflict
        if scenario == .replacement {
            try Data("original destination".utf8).write(to: destination)
            conflict = .replace(try parent.proveFile(Data("destination".utf8), progress: { _ in }))
        } else { conflict = .createNew }
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy,
            sources: [.init(account: .init(hostIdentity: "remote", accountIdentity: "remote"), path: .unix(Data("/source".utf8)))],
            destination: .init(account: account, path: .unix(Data(destination.path.utf8))), sourceObservations: [observed],
            conflict: conflict, payloadProof: scenario == .file ? try .data(Data("file bytes".utf8)) : manifest.proof,
            sourceManifest: manifest, treeProof: scenario == .file ? nil : manifest.proof)
        let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: journal.epoch,
            intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        do {
            let ownership = try await journal.acquireItem(intent.id)
            _ = try journal.accept(intent, digest: identity.intentDigest, ownership: ownership)
        }
        if scenario == .cancelled {
            try journal.requestCancellation(intent.id)
            do {
                _ = try await LocalTransferPublication.prepare(source, identity: identity, journal: journal)
                XCTFail("Cancelled preparation succeeded")
            } catch { XCTAssertEqual(try journal.read(intent.id).receipt?.outcome, .failedUnchanged) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            return
        }
        let ready = try await LocalTransferPublication.prepare(source, identity: identity, journal: journal)
        XCTAssertEqual(ready.phase, .readyToCommit)
        XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), scenario == .replacement)
        let repeated = try await LocalTransferPublication.prepare(source, identity: identity, journal: journal)
        XCTAssertEqual(repeated, ready)
        if scenario == .competingName { try Data("competing writer".utf8).write(to: destination) }
        if scenario == .changedChild {
            guard case .unix(let path) = try XCTUnwrap(ready.preparedPayload?.location.path),
                  let name = String(data: path, encoding: .utf8) else { return XCTFail("Missing prepared path") }
            try Data("changed".utf8).write(to: URL(fileURLWithPath: name).appendingPathComponent("child"))
        }
        let ownership = try await journal.acquireItem(intent.id)
        if scenario == .competingName || scenario == .changedChild {
            do {
                _ = try await OperationPublication.publish(journal: journal, id: intent.id, ownership: ownership)
                XCTFail("Unverified publication succeeded")
            } catch {
                if scenario == .competingName { XCTAssertEqual(try Data(contentsOf: destination), Data("competing writer".utf8)) } else { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
            }
        } else {
            let receipt = try await OperationPublication.publish(journal: journal, id: intent.id, ownership: ownership)
            XCTAssertEqual(receipt.outcome, .committed)
            XCTAssertEqual(try parent.manifest(Data("destination".utf8), progress: { _ in }).proof, manifest.proof)
            if scenario == .replacement {
                let retained = try XCTUnwrap(receipt.recovery.first { $0.purpose == .displacedOriginal })
                guard case .unix(let path) = try XCTUnwrap(retained.knownLocation?.path),
                      let name = String(data: path, encoding: .utf8) else { return XCTFail("Missing retained original") }
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: name)), Data("original destination".utf8))
            }
        }
        XCTAssertEqual(try parent.manifest(Data("staged".utf8), progress: { _ in }), manifest)
    }
}
