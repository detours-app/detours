import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

final class RemoteOperationCoordinatorTests: XCTestCase {
    func testOperationOwnershipSurvivesIdleGraceUntilCommitFinishes() async throws {
        let fixture = try await CoordinatorFixture(pauseAfterPreparation: true)
        defer { fixture.cleanup() }
        let pane = try await fixture.session.acquireLifetime(.pane)
        let ready = try await fixture.session.ensureReady()
        let running = Task { try await fixture.perform() }
        try await fixture.boundary.waitUntilPaused()
        await pane.releaseAndWait()
        try await Task.sleep(for: .milliseconds(80))
        try await fixture.session.requireGeneration(ready.generation)
        await fixture.boundary.resume()
        let result = try await running.value
        XCTAssertEqual(result.outcome, .committed)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.session.state != .disconnected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let finalState = await fixture.session.state
        XCTAssertEqual(finalState, .disconnected)
        XCTAssertEqual(try fixture.store.load(fixture.intent.id.operation).items.first?.result.outcome, .committed)
        await fixture.session.disconnect()
    }

    func testCancellationBeforeAcceptanceSendsNoMutation() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await coordinator.cancel(fixture.intent.id.operation)
        do {
            _ = try await coordinator.perform(fixture.intent, hostID: fixture.hostID, work: .copy)
            XCTFail("Cancelled operation accepted a new item")
        } catch OperationContractError.cancelled {}
        let requests = await fixture.boundary.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        await fixture.session.disconnect()
    }

    func testLostCommitReplyIsRecoveredWithoutRepeatingTheFileChange() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        let first = try await fixture.perform()
        XCTAssertEqual(first.outcome, .unknown)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        let restarted = fixture.coordinator()
        let restored = try await restarted.restore()
        XCTAssertEqual(restored.first?.items.first?.result.outcome, .unknown)
        let duplicate = try await restarted.perform(fixture.intent, hostID: fixture.hostID, work: .copy)
        XCTAssertEqual(duplicate.outcome, .unknown)
        let beforeCheck = await fixture.boundary.requests
        XCTAssertEqual(beforeCheck, [.accept, .prepare, .commit])
        let resolved = try await restarted.checkResult(fixture.intent.id)
        XCTAssertEqual(resolved.outcome, .committed)
        let firstUndo = try await restarted.takeUndoRegistration(fixture.intent.id)
        XCTAssertNotNil(firstUndo)
        _ = try await restarted.checkResult(fixture.intent.id)
        let secondUndo = try await fixture.coordinator().takeUndoRegistration(fixture.intent.id)
        XCTAssertNil(secondUndo)
        let requests = await fixture.boundary.requests
        XCTAssertEqual(requests, [.accept, .prepare, .commit, .status, .status])
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testLostAcceptanceReplyNeverStartsPreparationOnRestart() async throws {
        let fixture = try await CoordinatorFixture(loss: .accept)
        defer { fixture.cleanup() }
        let result = try await fixture.perform()
        XCTAssertEqual(result.outcome, .unknown)
        let restarted = fixture.coordinator()
        _ = try await restarted.restore()
        _ = try await restarted.perform(fixture.intent, hostID: fixture.hostID, work: .copy)
        _ = try await restarted.checkResult(fixture.intent.id)
        let requests = await fixture.boundary.requests
        XCTAssertEqual(requests, [.accept, .status])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testLostPreparationReplyDoesNotPublishThroughCheckResult() async throws {
        let fixture = try await CoordinatorFixture(loss: .prepare)
        defer { fixture.cleanup() }
        let result = try await fixture.perform()
        XCTAssertEqual(result.outcome, .unknown)
        let restarted = fixture.coordinator()
        _ = try await restarted.restore()
        let checked = try await restarted.checkResult(fixture.intent.id)
        XCTAssertEqual(checked.outcome, .unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let requests = await fixture.boundary.requests
        XCTAssertEqual(requests, [.accept, .prepare, .status])
        await fixture.session.disconnect()
    }

    func testCancellationRecordedBeforeCommitPreventsPublication() async throws {
        let fixture = try await CoordinatorFixture(pauseAfterPreparation: true)
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let running = Task { try await coordinator.perform(fixture.intent, hostID: fixture.hostID, work: .copy) }
        try await fixture.boundary.waitUntilPaused()
        try await coordinator.cancel(fixture.intent.id.operation)
        await fixture.boundary.resume()
        let result = try await running.value
        XCTAssertTrue(result.cancellationRequested)
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        let requests = await fixture.boundary.requests
        XCTAssertEqual(requests, [.accept, .prepare, .cancel])
        let saved = try fixture.store.load(fixture.intent.id.operation)
        XCTAssertTrue(saved.record.cancellationRequested)
        XCTAssertFalse(try XCTUnwrap(saved.items.first).sent.contains(.commit))
        await fixture.session.disconnect()
    }

    func testChangedEpochCannotSupplyEvidenceForOldOperation() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        _ = try await fixture.perform()
        let replacement = try await ServerOperationService(root: fixture.root.appendingPathComponent("replacement"),
                                                           account: fixture.account)
        let transport = CoordinatorTransport(service: replacement)
        let session = RemoteHostSession(transport: transport, publish: { _, _ in })
        let endpoint = RemoteOperationCoordinator.Endpoint(session: session, request: { request in
            XCTFail("An old-epoch request reached the replacement host journal")
            return try await replacement.reply(to: request)
        }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let coordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
        do {
            _ = try await coordinator.checkResult(fixture.intent.id)
            XCTFail("A changed epoch was accepted")
        } catch OperationCompatibilityError.epochChanged {}
        XCTAssertEqual(try fixture.store.load(fixture.intent.id.operation).items.first?.result.outcome, .unknown)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        await session.disconnect()
        await fixture.session.disconnect()
    }

    func testCancellationAfterCommitDoesNotEraseConfirmedDestination() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let committed = try await coordinator.perform(fixture.intent, hostID: fixture.hostID, work: .copy)
        XCTAssertEqual(committed.outcome, .committed)
        try await coordinator.cancel(fixture.intent.id.operation)
        let result = try await coordinator.checkResult(fixture.intent.id)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertTrue(result.cancellationRequested)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testChangedIntentIsRejectedBeforeAnyAdditionalRequest() async throws {
        let fixture = try await CoordinatorFixture(loss: .accept)
        defer { fixture.cleanup() }
        _ = try await fixture.perform()
        let changed = OperationIntent(id: fixture.intent.id, action: .trash, sources: fixture.intent.sources,
                                      destination: nil, sourceObservations: fixture.intent.sourceObservations,
                                      conflict: .createNew)
        do {
            _ = try await fixture.coordinator().perform(changed, hostID: fixture.hostID, work: .execute)
            XCTFail("Changed intent was accepted")
        } catch OperationContractError.intentMismatch {}
        let requests = await fixture.boundary.requests
        XCTAssertEqual(requests, [.accept])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        await fixture.session.disconnect()
    }
}

final class CoordinatorFixture: @unchecked Sendable {
    let root: URL
    let source: URL
    let destination: URL
    let bytes = Data("verified remote content".utf8)
    let account = OperationAccount(hostIdentity: "fixture-host", accountIdentity: "fixture-account")
    let hostID = UUID()
    let store: RemoteOperationStore
    let session: RemoteHostSession
    let boundary: CoordinatorBoundary
    let intent: OperationIntent

    init(loss: CoordinatorBoundary.Kind? = nil, pauseAfterPreparation: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Coordinator-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        try bytes.write(to: source)
        store = try RemoteOperationStore(root: root.appendingPathComponent("client"))
        let service = try await ServerOperationService(root: root.appendingPathComponent("host"), account: account)
        session = RemoteHostSession(transport: CoordinatorTransport(service: service), idleGrace: .milliseconds(30), publish: { _, _ in })
        let operation = UUID()
        try store.save(.init(operation: operation))
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let observation = try directory.proveFile(Data("source".utf8), progress: { _ in })
        intent = OperationIntent(id: OperationItemID(operation: operation, item: UUID()), action: .copy,
                                 sources: [OperationLocation(account: account, path: .unix(Data(source.path.utf8)))],
                                 destination: OperationLocation(account: account, path: .unix(Data(destination.path.utf8))),
                                 sourceObservations: [observation], conflict: .createNew)
        boundary = CoordinatorBoundary(service: service, store: store, loss: loss, pauseAfterPreparation: pauseAfterPreparation)
    }

    func coordinator() -> RemoteOperationCoordinator {
        let boundary = boundary
        let endpoint = RemoteOperationCoordinator.Endpoint(session: session, request: { try await boundary.send($0) },
                                                           upload: { _, _ in throw OperationContractError.invalidReceipt })
        return RemoteOperationCoordinator(store: store, resolve: { _ in endpoint })
    }

    func perform() async throws -> OperationOutcomeReducer {
        try await coordinator().perform(intent, hostID: hostID, work: .copy)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct CoordinatorTransport: RemoteHostSessionTransport {
    let service: ServerOperationService
    func handshake(generation: UInt64,
                   onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        guard case .handshake(let handshake) = try await service.reply(to: .handshake) else {
            throw OperationContractError.invalidReceipt
        }
        return handshake
    }
    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}

actor CoordinatorBoundary {
    enum Kind { case accept, prepare, commit, execute, status, cancel }
    enum Failure: Error { case lostReply, notPersisted, timeout }
    let service: ServerOperationService
    let store: RemoteOperationStore
    let loss: Kind?
    let pauseAfterPreparation: Bool
    var requests: [Kind] = []
    private var lossItem: OperationItemID?
    private var paused: CheckedContinuation<Void, Never>?

    init(service: ServerOperationService, store: RemoteOperationStore, loss: Kind?, pauseAfterPreparation: Bool) {
        self.service = service
        self.store = store
        self.loss = loss
        self.pauseAfterPreparation = pauseAfterPreparation
    }

    func send(_ request: OperationRequest) async throws -> OperationReply {
        let identity: OperationRequestIdentity
        let kind: Kind
        let step: RemoteOperationStore.Step?
        switch request {
        case .accept(let value, _): (identity, kind, step) = (value, .accept, .accept)
        case .prepareCopy(let value): (identity, kind, step) = (value, .prepare, .prepare)
        case .commit(let value): (identity, kind, step) = (value, .commit, .commit)
        case .execute(let value): (identity, kind, step) = (value, .execute, .execute)
        case .status(let value): (identity, kind, step) = (value, .status, nil)
        case .cancel(let value): (identity, kind, step) = (value, .cancel, nil)
        default: throw OperationContractError.invalidReceipt
        }
        let saved = try store.load(identity.id.operation)
        guard let item = saved.items.first(where: { $0.identity == identity }),
              step == nil || item.pending == step,
              kind != .cancel || saved.record.cancellationRequested else { throw Failure.notPersisted }
        requests.append(kind)
        let reply = try await service.reply(to: request)
        if kind == .prepare && pauseAfterPreparation {
            await withCheckedContinuation { paused = $0 }
        }
        if kind == loss && (lossItem == nil || lossItem == identity.id) { throw Failure.lostReply }
        return reply
    }

    func waitUntilPaused() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while paused == nil {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func resume() {
        paused?.resume()
        paused = nil
    }

    func loseReply(onlyFor item: OperationItemID) { lossItem = item }
}
