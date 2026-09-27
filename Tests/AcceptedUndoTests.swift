import AppKit
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedUndoTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testUndoManagerRemovesOnlyTheRecordedCopy() async throws { try await run(.copy) }
    func testUndoRefusesChangedCopiedContents() async throws { try await run(.changedCopy) }
    func testUndoRestoresNativeMoveToItsExactOriginalName() async throws { try await run(.move) }
    func testUndoRefusesAnOccupiedOriginalName() async throws { try await run(.occupiedSource) }
    func testEarlierCopyRemainsUndoableAfterLaterFailure() async throws { try await run(.partial) }

    private enum Scenario { case copy, changedCopy, move, occupiedSource, partial }

    private func run(_ scenario: Scenario) async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = configure(fixture)
        let output = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let source = Location.remote(hostID: fixture.hostID, path: fixture.source.path)
        let destination = Location.remote(hostID: fixture.hostID, path: output.path)
        let target = output.appendingPathComponent("source")
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        do {
            if scenario == .move || scenario == .occupiedSource {
                _ = try await queue.move(items: [source], to: destination, undoManager: undo)
            } else {
                let sources = scenario == .partial ? [source, .remote(hostID: fixture.hostID, path: fixture.root.appendingPathComponent("missing").path)] : [source]
                _ = try await queue.copy(items: sources, to: destination, undoManager: undo)
                if scenario == .partial { XCTFail("The missing second item must fail") }
            }
        } catch { if scenario != .partial { throw error } }
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        let original = try XCTUnwrap(queue.remoteOperationResults.values.first)
        if scenario == .changedCopy { try Data("later contents".utf8).write(to: target) }
        if scenario == .occupiedSource { try Data("new occupant".utf8).write(to: fixture.source) }
        if scenario == .copy {
            undo.undo()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while queue.remoteOperationResults.count < 2 || queue.isRunning {
                guard ContinuousClock.now < deadline else { throw OperationContractError.invalidReceipt }
                try await Task.sleep(for: .milliseconds(10))
            }
        } else {
            do {
                _ = try await queue.undoAcceptedOperation(original)
                if scenario == .changedCopy || scenario == .occupiedSource { XCTFail("Unsafe undo succeeded") }
            } catch { if scenario != .changedCopy && scenario != .occupiedSource { throw error } }
        }
        let reverse = try XCTUnwrap(queue.remoteOperationResults.values.first(where: { $0.record.operation != original.record.operation }))
        XCTAssertTrue(reverse.items.allSatisfy { $0.result.intent.reverses != nil })
        if scenario == .changedCopy {
            XCTAssertEqual(try Data(contentsOf: target), Data("later contents".utf8))
            XCTAssertEqual(reverse.items.map(\.preflightFailure), [.recoveryChanged])
        } else if scenario == .occupiedSource {
            XCTAssertEqual(try Data(contentsOf: target), fixture.bytes)
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("new occupant".utf8))
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            XCTAssertTrue(reverse.items.allSatisfy { $0.outcome == .committed })
        }
    }

    func testReplacementUndoRetainsNewContentsAndRestoresRecordedOriginal() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = configure(fixture)
        let previous = Data("original destination".utf8)
        try previous.write(to: fixture.destination)
        let directory = try OperationDirectory(path: Data(fixture.root.path.utf8))
        let approved = try directory.proveFile(Data("destination".utf8), progress: { _ in })
        let coordinator = try queue.operationCoordinator()
        let operation = try await coordinator.create()
        let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .copy,
            sources: fixture.intent.sources, destination: fixture.intent.destination,
            sourceObservations: fixture.intent.sourceObservations, conflict: .replace(approved))
        let result = try await queue.performAcceptedMutation(.init(intent: intent, hostID: fixture.hostID, work: .copy))
        try queue.requireSuccessfulBatch(result)
        let reversed = try await queue.undoAcceptedOperation(result)
        XCTAssertEqual(reversed.items.map { $0.result.intent.action }, [.trash, .restore])
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        let retained = try XCTUnwrap(reversed.items.first?.result.receipt?.recovery.first(where: { $0.purpose == .sourceTrash })?.knownLocation)
        guard case .unix(let bytes) = retained.path else { return XCTFail("Expected Unix recovery path") }
        let path = try XCTUnwrap(String(bytes: bytes, encoding: .utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), fixture.bytes)
    }

    private func configure(_ fixture: CoordinatorFixture) -> FileOperationQueue {
        let service = fixture.boundary.service
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { try await service.reply(to: $0) }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { _ in endpoint }
        return queue
    }
}
