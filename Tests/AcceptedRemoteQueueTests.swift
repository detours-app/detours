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

    private func configure(_ fixture: CoordinatorFixture) async throws -> FileOperationQueue {
        let queue = FileOperationQueue.shared
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: fixture.boundary.service),
                                          transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID)
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
