import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteHostSessionTests: XCTestCase {
    func testRepeatedProcessExitsCannotRenewRecoveryBudget() async throws {
        let transport = ExitingHostTransport()
        let states = SessionStateRecorder()
        let session = RemoteHostSession(transport: transport, attemptLimit: .milliseconds(20), recoveryLimit: .milliseconds(90),
            recoveryDelays: [.milliseconds(5)], publish: { await states.append($0, generation: $1) })
        let started = ContinuousClock.now
        do { _ = try await session.ensureReady(); XCTFail("Exiting helpers became ready") } catch RemoteHostSessionError.failed(.processExited(255)) {}
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(80))
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        let attempts = await transport.attempts
        XCTAssertGreaterThan(attempts, 2)
        let connected = await states.containsConnected()
        XCTAssertFalse(connected)
        await session.disconnect()
    }

    func testCancelledReadinessWaiterDoesNotCancelSharedAttempt() async throws {
        let transport = ControlledHostTransport()
        let session = RemoteHostSession(transport: transport, publish: { _, _ in })
        let cancelled = expectation(description: "Cancelled caller returns before handshake completes")
        let first = Task {
            do {
                _ = try await session.ensureReady()
                XCTFail("Cancelled caller became ready")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected cancellation error: \(error)")
            }
        }
        let generation = await transport.nextStarted()
        let second = Task { try await session.ensureReady() }
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        await transport.complete(generation: generation, reply: .success(transport.validHandshake))
        let ready = try await second.value
        XCTAssertEqual(ready.handshake, transport.validHandshake)
        let count = await transport.startedCount()
        XCTAssertEqual(count, 1)
        await first.value
        await session.disconnect()
    }

    func testConcurrentReadinessWaitsForVerifiedHandshake() async throws {
        let transport = ControlledHostTransport()
        let states = SessionStateRecorder()
        let session = RemoteHostSession(transport: transport, publish: { await states.append($0, generation: $1) })
        let first = Task { try await session.ensureReady() }
        let second = Task { try await session.ensureReady() }
        let generation = await transport.nextStarted()
        let before = await session.state
        XCTAssertEqual(before, .connecting)
        let connected = await states.containsConnected()
        XCTAssertFalse(connected)
        await transport.complete(generation: generation, reply: .success(transport.validHandshake))
        let firstReady = try await first.value
        let secondReady = try await second.value
        XCTAssertEqual(firstReady, secondReady)
        XCTAssertEqual(firstReady.handshake, transport.validHandshake)
        let count = await transport.startedCount()
        XCTAssertEqual(count, 1)
        await session.disconnect()
    }

    func testIncompatibleHandshakeStopsWithoutRecovery() async throws {
        let transport = ControlledHostTransport()
        let states = SessionStateRecorder()
        let session = RemoteHostSession(transport: transport, publish: { await states.append($0, generation: $1) })
        let request = Task { try await session.ensureReady() }
        let generation = await transport.nextStarted()
        let invalid = OperationHandshake(version: 1, schemaVersion: 1, capabilities: [],
            account: transport.validHandshake.account, epoch: transport.validHandshake.epoch)
        await transport.complete(generation: generation, reply: .success(invalid))
        do { _ = try await request.value; XCTFail("Incompatible host became ready") } catch RemoteHostSessionError.failed(.compatibility(_)) {}
        let count = await transport.startedCount()
        XCTAssertEqual(count, 1)
        let connected = await states.containsConnected()
        XCTAssertFalse(connected)
        await session.disconnect()
    }

    func testDisconnectRejectsLateHandshakeAndDoesNotReopen() async throws {
        let transport = ControlledHostTransport()
        let states = SessionStateRecorder()
        let session = RemoteHostSession(transport: transport, publish: { await states.append($0, generation: $1) })
        let request = Task { try await session.ensureReady() }
        let generation = await transport.nextStarted()
        await session.disconnect()
        await transport.complete(generation: generation, reply: .success(transport.validHandshake))
        do { _ = try await request.value; XCTFail("Retired session became ready") } catch {}
        let connected = await states.containsConnected()
        XCTAssertFalse(connected)
        do { _ = try await session.ensureReady(); XCTFail("Retired session reopened") } catch RemoteHostSessionError.retired {}
        let count = await transport.startedCount()
        XCTAssertEqual(count, 1)
    }

    func testRecoveryDeadlineIncludesHangingHandshakes() async throws {
        let transport = ControlledHostTransport()
        let states = SessionStateRecorder()
        let session = RemoteHostSession(transport: transport, attemptLimit: .milliseconds(30), recoveryLimit: .milliseconds(90),
            recoveryDelays: [.milliseconds(5)], publish: { await states.append($0, generation: $1) })
        let clock = ContinuousClock()
        let started = clock.now
        do { _ = try await session.ensureReady(); XCTFail("Hanging handshake became ready") } catch RemoteHostSessionError.failed(.timedOut) {}
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
        let connected = await states.containsConnected()
        XCTAssertFalse(connected)
        let count = await transport.startedCount()
        XCTAssertGreaterThan(count, 1)
        XCTAssertLessThanOrEqual(count, 4)
        await session.disconnect()
        await transport.finishAll()
    }

    func testRecoveryRejectsChangedAccountAndObsoleteFailure() async throws {
        let transport = ControlledHostTransport()
        let states = SessionStateRecorder()
        let session = RemoteHostSession(transport: transport, recoveryDelays: [.milliseconds(1)],
            publish: { await states.append($0, generation: $1) })
        let initial = Task { try await session.ensureReady() }
        let first = await transport.nextStarted()
        await transport.complete(generation: first, reply: .success(transport.validHandshake))
        _ = try await initial.value
        await session.transportFailed(generation: first, reason: .processExited(255))
        let next = await transport.nextStarted()
        let waiting = Task { try await session.ensureReady() }
        await session.transportFailed(generation: first, reason: .hostKeyChanged)
        let wrong = OperationHandshake(version: 2, schemaVersion: 1, capabilities: Set(OperationCapability.allCases),
            account: .init(hostIdentity: "different", accountIdentity: "different"), epoch: transport.validHandshake.epoch)
        await transport.complete(generation: next, reply: .success(wrong))
        do { _ = try await waiting.value; XCTFail("Changed account became ready") } catch RemoteHostSessionError.failed(.compatibility(_)) {}
        let count = await transport.startedCount()
        XCTAssertEqual(count, 2)
        do { try await session.requireGeneration(first); XCTFail("Old generation remained usable") } catch RemoteHostSessionError.obsoleteGeneration {}
        await session.disconnect()
    }
}

private actor SessionStateRecorder {
    private var values: [SSHConnectionState] = []
    func append(_ value: SSHConnectionState, generation: UInt64) { values.append(value) }
    func containsConnected() -> Bool { values.contains(.connected) }
}

private actor ExitingHostTransport: RemoteHostSessionTransport {
    private(set) var attempts = 0
    func handshake(generation: UInt64, onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        attempts += 1
        throw RemoteHostSessionError.failed(.processExited(255))
    }
    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}

private actor ControlledHostTransport: RemoteHostSessionTransport {
    nonisolated let validHandshake = OperationHandshake(version: 2, schemaVersion: 1, capabilities: Set(OperationCapability.allCases),
        account: .init(hostIdentity: "fixture-host", accountIdentity: "fixture-user"), epoch: UUID())
    private var pending: [UInt64: CheckedContinuation<OperationHandshake, Error>] = [:]
    private var started: [UInt64] = []
    private var unconsumed: [UInt64] = []
    private var nextWaiters: [CheckedContinuation<UInt64, Never>] = []

    func handshake(generation: UInt64, onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        try await withCheckedThrowingContinuation { continuation in
            pending[generation] = continuation
            started.append(generation)
            if nextWaiters.isEmpty { unconsumed.append(generation) } else { nextWaiters.removeFirst().resume(returning: generation) }
        }
    }

    func nextStarted() async -> UInt64 {
        if !unconsumed.isEmpty { return unconsumed.removeFirst() }
        return await withCheckedContinuation { nextWaiters.append($0) }
    }

    func startedCount() -> Int { started.count }
    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
    func complete(generation: UInt64, reply: Result<OperationHandshake, Error>) {
        pending.removeValue(forKey: generation)?.resume(with: reply)
    }
    func finishAll() {
        let remaining = Array(pending.values)
        pending.removeAll()
        for continuation in remaining { continuation.resume(throwing: CancellationError()) }
    }
}
