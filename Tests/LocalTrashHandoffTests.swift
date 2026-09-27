import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

/// T18: the native macOS Trash handoff for a local source disposition, with the
/// Trash call injected so a confirmed, known-unchanged and lost-return handoff can
/// each be exercised against real temporary files.
final class LocalTrashHandoffTests: XCTestCase {
    func testConfirmedNativeTrashHandoffRecordsKnownLocation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trashDirectory = root.appendingPathComponent("Trash", isDirectory: true)
        let fixture = try await makeFixture(trashItem: { url in
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let destination = trashDirectory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let receipt = try await fixture.service.trash(fixture.identity)

        XCTAssertEqual(receipt.outcome, .committed)
        XCTAssertEqual(receipt.sourceDisposition, .confirmed)
        XCTAssertTrue(receipt.recovery.contains { $0.purpose == .sourceTrash && $0.knownLocation != nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testKnownUnchangedHandoffRetainsTheOriginal() async throws {
        let fixture = try await makeFixture(trashItem: { _ in nil })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let receipt = try await fixture.service.trash(fixture.identity)

        // The object never moved, so it is retained with a known holding location.
        XCTAssertEqual(receipt.outcome, .committed)
        XCTAssertTrue(receipt.recovery.contains { $0.purpose == .sourceTrash && $0.knownLocation != nil })
    }

    func testLostReturnHandoffStaysUnknown() async throws {
        let fixture = try await makeFixture(trashItem: { url in
            // The item moves but the handoff never reports where it went.
            let moved = url.deletingLastPathComponent().appendingPathComponent("moved-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved)
            return nil
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let receipt = try await fixture.service.trash(fixture.identity)

        XCTAssertEqual(receipt.outcome, .unknown)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func makeFixture(
        trashItem: @escaping @Sendable (URL) throws -> URL?
    ) async throws -> (service: LocalTransferService, identity: OperationRequestIdentity, source: URL, root: URL) {
        let root = try makeRoot()
        let account = OperationAccount(hostIdentity: "local-host", accountIdentity: "uid:501")
        let journal = try await OperationJournal(root: root.appendingPathComponent("journal", isDirectory: true), account: account)
        let source = root.appendingPathComponent("original.txt")
        try Data("original content".utf8).write(to: source)
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let manifest = try directory.manifest(Data("original.txt".utf8), progress: { _ in })
        let itemID = OperationItemID(operation: UUID(), item: UUID())
        let location = OperationLocation(account: account, path: .unix(Data(source.path.utf8)))
        let intent = OperationIntent(id: itemID, action: .trash, sources: [location], destination: nil,
            sourceObservations: manifest.entries.map(\.observation), conflict: .createNew, sourceManifest: manifest)
        let digest = try OperationContentProof.data(intent.canonicalData()).sha256
        let identity = OperationRequestIdentity(id: itemID, account: account, epoch: journal.epoch, intentDigest: digest)
        let ownership = try await journal.acquireItem(itemID)
        _ = try journal.accept(intent, digest: digest, ownership: ownership)
        return (LocalTransferService(journal: journal, trashItem: trashItem), identity, source, root)
    }
}
