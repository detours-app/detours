import AppKit
import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedRemoteMergeTests: XCTestCase {
    override func setUp() async throws { FileOperationQueue.shared.resetRemoteQueueStateForTesting() }
    override func tearDown() async throws { FileOperationQueue.shared.resetRemoteQueueStateForTesting() }

    func testMergePreservesUnrelatedContentsAndRecordsEachChild() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let (source, destination) = try setup(fixture)
        let plan = try await plan(fixture, source: source, destination: destination, isMove: false)
        let result = try await fixture.coordinator().performBatch(plan.items, operation: fixture.intent.id.operation,
                                                                selections: plan.selections)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .committed])
        XCTAssertEqual(result.outcome(for: try XCTUnwrap(result.selections?.first)), .committed)
        XCTAssertEqual(try contents(destination, "merge/a"), "first")
        XCTAssertEqual(try contents(destination, "merge/z"), "last")
        XCTAssertEqual(try contents(destination, "merge/unrelated"), "preserve")
        XCTAssertEqual(try contents(source, "a"), "first")
        XCTAssertEqual(result.selections?.first?.children, result.items.map { $0.identity.id })
        await fixture.session.disconnect()
    }

    func testLaterChildFailureRetainsEarlierUndoAndWholeSourceFolder() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let (source, destination) = try setup(fixture)
        let plan = try await plan(fixture, source: source, destination: destination, isMove: true)
        try Data("changed".utf8).write(to: source.appendingPathComponent("z"))
        let coordinator = fixture.coordinator()
        let result = try await coordinator.performBatch(plan.items, operation: fixture.intent.id.operation,
                                                       selections: plan.selections)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .failedUnchanged, .notStarted])
        XCTAssertEqual(result.outcome(for: try XCTUnwrap(result.selections?.first)), .partial)
        XCTAssertEqual(try contents(source, "a"), "first")
        XCTAssertEqual(try contents(source, "z"), "changed")
        XCTAssertEqual(try contents(destination, "merge/a"), "first")
        XCTAssertEqual(try contents(destination, "merge/unrelated"), "preserve")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("merge/z").path))
        let undo = try await coordinator.takeUndoRegistration(plan.items[0].intent.id)
        let repeated = try await coordinator.takeUndoRegistration(plan.items[0].intent.id)
        XCTAssertNotNil(undo)
        XCTAssertNil(repeated)
        XCTAssertTrue(result.items[2].sent.isEmpty)
        await fixture.session.disconnect()
    }

    func testSkippedChildPreventsSourceFolderDisposition() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let (source, destination) = try setup(fixture)
        try Data("existing".utf8).write(to: destination.appendingPathComponent("merge/z"))
        FileOperationQueue.shared.conflictChoiceOverrideForTesting = .skip
        defer { FileOperationQueue.shared.conflictChoiceOverrideForTesting = nil }
        let plan = try await plan(fixture, source: source, destination: destination, isMove: true)
        let result = try await fixture.coordinator().performBatch(plan.items, operation: fixture.intent.id.operation,
                                                                selections: plan.selections)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .notStarted, .notStarted])
        XCTAssertEqual(result.outcome(for: try XCTUnwrap(result.selections?.first)), .partial)
        XCTAssertEqual(try contents(source, "a"), "first")
        XCTAssertEqual(try contents(source, "z"), "last")
        XCTAssertEqual(try contents(destination, "merge/z"), "existing")
        XCTAssertTrue(result.items[2].sent.isEmpty)
        await fixture.session.disconnect()
    }

    func testSuccessfulMergeMoveTrashesOnlyProvenSelectedSource() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let (source, destination) = try setup(fixture)
        let plan = try await plan(fixture, source: source, destination: destination, isMove: true)
        let result = try await fixture.coordinator().performBatch(plan.items, operation: fixture.intent.id.operation,
                                                                selections: plan.selections)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .committed, .committed])
        XCTAssertEqual(result.outcome(for: try XCTUnwrap(result.selections?.first)), .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try contents(destination, "merge/a"), "first")
        XCTAssertEqual(try contents(destination, "merge/z"), "last")
        XCTAssertEqual(try contents(destination, "merge/unrelated"), "preserve")
        XCTAssertNotNil(result.items.last?.result.receipt?.recovery.first { $0.purpose == .sourceTrash })
        var changed = result
        changed.selections = []
        XCTAssertThrowsError(try fixture.store.save(changed))
        await fixture.session.disconnect()
    }

    func testIdenticalReplacementOfNestedSourceAfterCopiesPreventsFolderTrash() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let (source, destination) = try setup(fixture)
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let child = nested.appendingPathComponent("child")
        let bytes = Data("same bytes".utf8)
        try bytes.write(to: child)
        let plan = try await plan(fixture, source: source, destination: destination, isMove: true)
        let manifest = try XCTUnwrap(plan.items.last?.intent.sourceManifest)
        let lastCopy = try XCTUnwrap(plan.items.dropLast().last?.intent.id)
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            let reply = try await fixture.boundary.send(request)
            if case .commit(let identity) = request, identity.id == lastCopy {
                try FileManager.default.moveItem(at: child, to: fixture.root.appendingPathComponent("held-child"))
                try bytes.write(to: child)
            }
            return reply
        }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let coordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
        let result = try await coordinator.performBatch(plan.items, operation: fixture.intent.id.operation, selections: plan.selections)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .committed, .committed, .failedUnchanged])
        let actual = try OperationDirectory(path: Data(source.deletingLastPathComponent().path.utf8))
            .manifest(Data(source.lastPathComponent.utf8), progress: { _ in })
        XCTAssertEqual(actual.proof, manifest.proof)
        XCTAssertEqual(actual.entries.first?.observation, manifest.entries.first?.observation)
        XCTAssertNotEqual(actual, manifest)
        XCTAssertEqual(try Data(contentsOf: child), bytes)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("merge/nested/child")), bytes)
        await fixture.session.disconnect()
    }

    func testLostWorkerAfterTrashDoesNotReconcileReplacedNestedObjectAsSuccess() async throws {
        let fixture = try await CoordinatorFixture(afterTrashMove: { location in
            guard case .unix(let raw) = location.path, let path = String(data: raw, encoding: .utf8) else {
                throw OperationFilesystemError.invalidPath
            }
            let moved = URL(fileURLWithPath: path)
            let child = moved.appendingPathComponent("nested/child")
            try FileManager.default.moveItem(at: child, to: moved.deletingLastPathComponent().appendingPathComponent("held-child"))
            try Data("same bytes".utf8).write(to: child)
            throw OperationContractError.invalidReceipt
        })
        defer { fixture.cleanup() }
        let (source, destination) = try setup(fixture)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data("same bytes".utf8).write(to: source.appendingPathComponent("nested/child"))
        let plan = try await plan(fixture, source: source, destination: destination, isMove: true)
        let coordinator = fixture.coordinator()
        let result = try await coordinator.performBatch(plan.items, operation: fixture.intent.id.operation, selections: plan.selections)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .committed, .committed, .unknown])
        XCTAssertEqual(result.items.last?.result.receipt?.sourceDisposition, .unknown)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("merge/nested/child")), Data("same bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let requests = await fixture.boundary.requests
        _ = try await coordinator.performBatch(plan.items, operation: fixture.intent.id.operation, selections: plan.selections)
        let repeated = await fixture.boundary.requests
        XCTAssertEqual(requests, repeated)
        await fixture.session.disconnect()
    }

    private func setup(_ fixture: CoordinatorFixture) throws -> (URL, URL) {
        let source = fixture.root.appendingPathComponent("merge")
        let destination = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("merge"), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: source.appendingPathComponent("a"))
        try Data("last".utf8).write(to: source.appendingPathComponent("z"))
        try Data("preserve".utf8).write(to: destination.appendingPathComponent("merge/unrelated"))
        return (source, destination)
    }

    private func plan(_ fixture: CoordinatorFixture, source: URL, destination: URL, isMove: Bool) async throws -> RemoteTransferPlan {
        let queue = FileOperationQueue.shared
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: fixture.boundary.service),
                                          transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID)
        queue.acceptedCoordinator = fixture.coordinator()
        var plan = RemoteTransferPlan(hostID: fixture.hostID, operation: fixture.intent.id.operation, mergeDirectories: true)
        try await queue.planRemoteItem(.remote(hostID: fixture.hostID, path: source.path),
            directory: .unix(Data(destination.path.utf8)), isMove: isMove, plan: &plan)
        return plan
    }

    private func contents(_ root: URL, _ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
