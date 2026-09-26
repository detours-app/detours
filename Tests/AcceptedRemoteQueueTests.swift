import AppKit
import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedRemoteQueueTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testQueueContinuesAfterMissingSourceAndRetainsCompletedUndo() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = try await configure(fixture)
        let destination = try destination(fixture)
        let missing = Location.remote(hostID: fixture.hostID, path: fixture.root.appendingPathComponent("missing").path)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        do {
            _ = try await queue.copy(items: [source(fixture), missing], to: destination, undoManager: undo)
            XCTFail("A missing item became whole-batch success")
        } catch let failure as RemoteBatchFailure {
            XCTAssertEqual(failure.snapshot.items.map(\.outcome), [.committed, .failedUnchanged])
            XCTAssertEqual(failure.snapshot.items[1].preflightFailure, .sourceMissing)
            XCTAssertTrue(failure.snapshot.items[1].sent.isEmpty)
        }
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path).appendingPathComponent("source")), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testQueueDoesNotTreatDeniedOrDisconnectedDestinationAsMissing() async throws {
        for lookup in [OperationLookup<OperationObservation>.denied, .disconnected] {
            let fixture = try await CoordinatorFixture()
            defer { fixture.cleanup() }
            let queue = try await configure(fixture)
            let destination = try destination(fixture)
            let service = fixture.boundary.service
            let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
                if case .lookup(let location) = request, location.path != fixture.intent.sources[0].path {
                    return .lookup(lookup)
                }
                if case .lookup = request { return try await service.reply(to: request) }
                XCTFail("A failed destination lookup authorized mutation")
                throw OperationContractError.invalidReceipt
            }, upload: { _, _ in throw OperationContractError.invalidReceipt })
            queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
            let result = try await queue.performAcceptedRemoteTransfer(items: [source(fixture)], to: destination, isMove: false)
            XCTAssertTrue(try XCTUnwrap(result.items.first).sent.isEmpty)
            XCTAssertNotNil(result.items.first?.preflightFailure)
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination.path).appendingPathComponent("source").path))
            await fixture.session.disconnect()
        }
    }

    func testQueueRetainsLostReplyResultWithoutCallingLegacyCopy() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        let queue = try await configure(fixture)
        let destination = try destination(fixture)
        let result = try await queue.performAcceptedRemoteTransfer(items: [source(fixture)], to: destination, isMove: false)
        XCTAssertEqual(result.items.first?.outcome, .committed)
        XCTAssertEqual(queue.remoteOperationResults[result.record.operation], result)
        let requests = await fixture.boundary.requests
        XCTAssertEqual(requests.filter { $0 == .commit }.count, 1)
        XCTAssertEqual(requests.filter { $0 == .status }.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path).appendingPathComponent("source")), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testQueueSkipPreservesExistingFileWithoutSendingAcceptance() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = try await configure(fixture)
        let destination = try destination(fixture)
        let target = URL(fileURLWithPath: destination.path).appendingPathComponent("source")
        try Data("original".utf8).write(to: target)
        queue.conflictChoiceOverrideForTesting = .skip
        defer { queue.conflictChoiceOverrideForTesting = nil }
        let result = try await queue.performAcceptedRemoteTransfer(items: [source(fixture)], to: destination, isMove: false)
        XCTAssertEqual(result.items.first?.result.intent.conflict, .skip)
        XCTAssertTrue(try XCTUnwrap(result.items.first).sent.isEmpty)
        try queue.requireSuccessfulBatch(result)
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        await fixture.session.disconnect()
    }

    func testKeepBothRetainsOriginalAndCommitsNumberedDestination() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = try await configure(fixture)
        let destination = try destination(fixture)
        let directory = URL(fileURLWithPath: destination.path)
        try Data("original".utf8).write(to: directory.appendingPathComponent("source"))
        queue.conflictChoiceOverrideForTesting = .keepBoth
        defer { queue.conflictChoiceOverrideForTesting = nil }
        let copied = try await queue.copy(items: [source(fixture)], to: destination)
        XCTAssertEqual(copied, [destination.appendingPathComponent("source 2")])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("source")), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("source 2")), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testMoveUsesConfirmedSourceDispositionAndRetainsUndo() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = try await configure(fixture)
        let destination = try destination(fixture)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let moved = try await queue.move(items: [source(fixture)], to: destination, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(moved, [destination.appendingPathComponent("source")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path).appendingPathComponent("source")), fixture.bytes)
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        XCTAssertEqual(result.items.first?.result.receipt?.sourceDisposition, .confirmed)
        XCTAssertTrue(undo.canUndo)
        await fixture.session.disconnect()
    }

    func testLegacyDisconnectDoesNotCancelAcceptedTransfer() async throws {
        let fixture = try await CoordinatorFixture(pauseAfterPreparation: true)
        defer { fixture.cleanup() }
        let queue = try await configure(fixture)
        let destination = try destination(fixture)
        let source = source(fixture)
        let transfer = Task { try await queue.copy(items: [source], to: destination) }
        try await fixture.boundary.waitUntilPaused()
        queue.handleSSHConnectionStateChange(.init(hostID: fixture.hostID, oldState: .connected,
            newState: .failed(reason: .transport("legacy monitor lost contact"))))
        XCTAssertFalse(queue.isRemoteHostPausedForTesting(fixture.hostID))
        await fixture.boundary.resume()
        let copied = try await transfer.value
        XCTAssertEqual(copied, [destination.appendingPathComponent("source")])
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        XCTAssertFalse(result.record.cancellationRequested)
        XCTAssertEqual(result.items.first?.outcome, .committed)
        await fixture.session.disconnect()
    }

    func testNewFolderPublishesOnlyAfterEveryChildIsPrepared() async throws {
        let fixture = try await CoordinatorFixture(pauseAfterPreparation: true)
        defer { fixture.cleanup() }
        let queue = try await configure(fixture)
        let source = try folderSource(fixture)
        let destination = try destination(fixture)
        let transfer = Task { try await queue.copy(items: [source], to: destination) }
        try await fixture.boundary.waitUntilPaused()
        let final = URL(fileURLWithPath: destination.path).appendingPathComponent("folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        await fixture.boundary.resume()
        let copied = try await transfer.value
        XCTAssertEqual(copied, [destination.appendingPathComponent("folder")])
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("first")), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("nested/last")), Data("last child".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.appendingPathComponent("empty").path))
        await fixture.session.disconnect()
    }

    func testChangedLaterFolderPayloadPreventsWholeFolderPublication() async throws {
        let fixture = try await CoordinatorFixture(pauseAfterPreparation: true)
        defer { fixture.cleanup() }
        let queue = try await configure(fixture)
        let source = try folderSource(fixture)
        let destination = try destination(fixture)
        let transfer = Task { try await queue.copy(items: [source], to: destination) }
        try await fixture.boundary.waitUntilPaused()
        let record = try XCTUnwrap(fixture.store.all().first { !$0.items.isEmpty })
        let item = try XCTUnwrap(record.items.first)
        let host = try fixture.boundary.service.status(item.identity)
        let payload = try XCTUnwrap(host.receipt?.preparedPayload)
        guard case .unix(let bytes) = payload.location.path,
              let path = String(data: bytes, encoding: .utf8) else {
            await fixture.boundary.resume()
            _ = try? await transfer.value
            return XCTFail("Expected native prepared folder")
        }
        try Data("damaged later child".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("nested/last"))
        await fixture.boundary.resume()
        do {
            _ = try await transfer.value
            XCTFail("A damaged child published the folder")
        } catch let error as RemoteBatchFailure {
            XCTAssertEqual(error.snapshot.items.first?.outcome, .failedUnchanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination.path).appendingPathComponent("folder").path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path).appendingPathComponent("nested/last")), Data("last child".utf8))
        await fixture.session.disconnect()
    }

    private func folderSource(_ fixture: CoordinatorFixture) throws -> Location {
        let root = fixture.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try fixture.bytes.write(to: root.appendingPathComponent("first"))
        try Data("last child".utf8).write(to: root.appendingPathComponent("nested/last"))
        return .remote(hostID: fixture.hostID, path: root.path)
    }

    private func configure(_ fixture: CoordinatorFixture) async throws -> FileOperationQueue {
        let queue = FileOperationQueue.shared
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: fixture.boundary.service),
                                          transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { try await fixture.boundary.send($0) },
            upload: { _, _ in throw FileProviderError.unsupportedOperation("unused") })
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = fixture.coordinator()
        return queue
    }

    private func source(_ fixture: CoordinatorFixture) -> Location { .remote(hostID: fixture.hostID, path: fixture.source.path) }

    private func destination(_ fixture: CoordinatorFixture) throws -> Location {
        let directory = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return .remote(hostID: fixture.hostID, path: directory.path)
    }
}
