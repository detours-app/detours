import Foundation
import os.log
import RemoteOperationSupport

protocol RemoteHostSessionTransport: Sendable {
    func handshake(generation: UInt64, onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake
    func retire(generation: UInt64) async
    func setActivePaneCount(_ count: Int) async
    func restoreWatches(generation: UInt64) async throws
}

extension RemoteHostSessionTransport {
    func restoreWatches(generation: UInt64) async throws {}
}

enum RemoteHostSessionError: Error, LocalizedError, Sendable {
    case failed(SSHConnectionFailureReason)
    case retired
    case obsoleteGeneration
    case invalidHandshake

    var errorDescription: String? {
        switch self {
        case .failed(let reason): return reason.displayMessage
        case .retired: return "This remote session has been closed."
        case .obsoleteGeneration: return "The remote connection changed while the request was running."
        case .invalidHandshake: return "The remote host did not return a compatible operation handshake."
        }
    }
}

actor RemoteHostSession: RemoteConnectionHandle {
    struct Ready: Equatable, Sendable {
        let generation: UInt64
        let handshake: OperationHandshake
    }

    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case ready(Ready)
        case recovering(attempt: Int, nextDelay: TimeInterval)
        case failed(SSHConnectionFailureReason)
    }

    private let transport: any RemoteHostSessionTransport
    private let publish: @Sendable (SSHConnectionState, UInt64) async -> Void
    private let clock = ContinuousClock()
    private let attemptLimit: Duration
    private let recoveryLimit: Duration
    private let recoveryDelays: [Duration]
    private var generation: UInt64 = 0
    private var retired = false
    private var expectedAccount: OperationAccount?
    private var expectedEpoch: UUID?
    private var connectionTask: Task<Ready, Error>?
    private var attempt: RemoteHandshakeAttempt?
    private let idleGrace: Duration
    private var lifetimes: [UUID: RemoteSessionLifetimeKind] = [:]
    private var idleTask: Task<Void, Never>?
    private var idleRevision: UInt64 = 0
    private var idleRetirement: Task<Void, Never>?
    private var workers: [UUID: RemoteProcessWorker] = [:]
    private static let logger = Logger(subsystem: "com.detours", category: "remote-worker")
    private(set) var state: State = .disconnected

    init(
        transport: any RemoteHostSessionTransport,
        attemptLimit: Duration = .seconds(10),
        recoveryLimit: Duration = .seconds(60),
        recoveryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)],
        idleGrace: Duration = .seconds(300),
        publish: @escaping @Sendable (SSHConnectionState, UInt64) async -> Void
    ) {
        precondition(attemptLimit > .zero && recoveryLimit > .zero && !recoveryDelays.isEmpty)
        precondition(recoveryDelays.allSatisfy { $0 > .zero })
        self.transport = transport
        self.attemptLimit = attemptLimit
        self.recoveryLimit = recoveryLimit
        self.recoveryDelays = recoveryDelays
        self.idleGrace = idleGrace
        self.publish = publish
    }

    func ensureReady() async throws -> Ready {
        await idleRetirement?.value
        guard !retired else { throw RemoteHostSessionError.retired }
        if case .ready(let ready) = state { return ready }
        if let connectionTask { return try await RemoteReadinessWaiter<Ready>().wait(for: connectionTask) }
        if case .failed(let reason) = state { throw RemoteHostSessionError.failed(reason) }
        let task = Task { try await self.connectInitially() }
        connectionTask = task
        return try await RemoteReadinessWaiter<Ready>().wait(for: task)
    }

    func requireGeneration(_ expected: UInt64) throws {
        guard !retired, case .ready(let ready) = state, ready.generation == expected else {
            throw RemoteHostSessionError.obsoleteGeneration
        }
    }

    func performOwnedWorker<Value: Sendable>(
        _ worker: RemoteProcessWorker,
        kind: RemoteSessionLifetimeKind,
        body: @escaping @Sendable (RemoteProcessWorker) throws -> Value
    ) async throws -> Value {
        try await withOwnedWorker(worker, kind: kind) { try await worker.perform(body) }
    }

    func withOwnedWorker<Value: Sendable>(
        _ worker: RemoteProcessWorker,
        kind: RemoteSessionLifetimeKind,
        body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let lifetime = try acquireLifetime(kind)
        defer { lifetime.release() }
        let ready = try await ensureReady()
        try Task.checkCancellation()
        try requireGeneration(ready.generation)
        let id = UUID()
        workers[id] = worker
        defer { workers.removeValue(forKey: id) }
        let result = try await body()
        try requireGeneration(ready.generation)
        return result
    }

    private func retireWorkers() async {
        let active = Array(workers.values)
        for worker in active { worker.requestStop() }
        for worker in active {
            do { try await worker.stop() } catch {
                Self.logger.error("Owned remote worker shutdown failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func forceReconnect() async throws {
        guard !retired else { throw RemoteHostSessionError.retired }
        let previous = generation
        let previousAttempt = attempt
        generation += 1
        connectionTask?.cancel()
        attempt = nil
        state = .connecting
        let task = Task {
            await self.retireWorkers()
            await previousAttempt?.cancel()
            await transport.retire(generation: previous)
            try Task.checkCancellation()
            return try await self.connectInitially()
        }
        connectionTask = task
        _ = try await RemoteReadinessWaiter<Ready>().wait(for: task)
    }

    func disconnect() async {
        guard !retired else { return }
        retired = true
        idleTask?.cancel()
        lifetimes.removeAll()
        await retireWorkers()
        await idleRetirement?.value
        await retireAttempt()
        state = .disconnected
        await publish(.disconnected, generation)
    }

    func setActivePaneCount(_ count: Int) async {
        await transport.setActivePaneCount(count)
    }

    func acquireLifetime(_ kind: RemoteSessionLifetimeKind) throws -> RemoteSessionLifetime {
        guard !retired else { throw RemoteHostSessionError.retired }
        try Task.checkCancellation()
        idleRevision += 1
        idleTask?.cancel()
        idleTask = nil
        let id = UUID()
        lifetimes[id] = kind
        return RemoteSessionLifetime(owner: self, id: id)
    }

    func releaseLifetime(_ id: UUID) {
        guard lifetimes.removeValue(forKey: id) != nil else { return }
        scheduleIdleRetirement()
    }

    private func scheduleIdleRetirement() {
        guard !retired, lifetimes.isEmpty else { return }
        idleRevision += 1
        let revision = idleRevision
        let grace = idleGrace
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: grace) } catch { return }
            await self?.retireIfIdle(revision: revision)
        }
    }

    private func retireIfIdle(revision: UInt64) {
        guard !retired, lifetimes.isEmpty, idleRevision == revision else { return }
        idleTask = nil
        let previous = generation
        generation += 1
        let retiredGeneration = generation
        let previousAttempt = attempt
        attempt = nil
        connectionTask?.cancel()
        connectionTask = nil
        state = .disconnected
        idleRetirement = Task {
            await previousAttempt?.cancel()
            await transport.retire(generation: previous)
            await publish(.disconnected, retiredGeneration)
        }
    }

    func transportFailed(generation failedGeneration: UInt64, reason: SSHConnectionFailureReason) async {
        guard !retired, failedGeneration == generation, case .ready = state, connectionTask == nil else { return }
        let deadline = clock.now.advanced(by: recoveryLimit)
        state = .recovering(attempt: 0, nextDelay: 0)
        let task = Task { try await self.recover(reason: reason, deadline: deadline) }
        connectionTask = task
    }

    private func connectInitially() async throws -> Ready {
        do {
            return try await connectOnce(deadline: clock.now.advanced(by: attemptLimit))
        } catch {
            try Task.checkCancellation()
            guard !retired else { throw RemoteHostSessionError.retired }
            return try await recover(reason: Self.reason(for: error), deadline: clock.now.advanced(by: recoveryLimit))
        }
    }

    private func recover(reason initialReason: SSHConnectionFailureReason, deadline: ContinuousClock.Instant) async throws -> Ready {
        var reason = initialReason
        var number = 0
        while !retired && !Task.isCancelled && SSHReconnectPolicy.isRetryable(reason) {
            let delay = recoveryDelays[min(number, recoveryDelays.count - 1)]
            guard clock.now.advanced(by: delay) < deadline else { break }
            number += 1
            state = .recovering(attempt: number, nextDelay: delay.timeInterval)
            await publish(.reconnecting(attempt: number, nextDelay: delay.timeInterval), generation)
            try await clock.sleep(for: delay)
            try Task.checkCancellation()
            do {
                return try await connectOnce(deadline: min(deadline, clock.now.advanced(by: attemptLimit)))
            } catch {
                try Task.checkCancellation()
                reason = Self.reason(for: error)
            }
        }
        try Task.checkCancellation()
        guard !retired else { throw RemoteHostSessionError.retired }
        connectionTask = nil
        state = .failed(reason)
        await publish(.failed(reason: reason), generation)
        throw RemoteHostSessionError.failed(reason)
    }

    private func connectOnce(deadline: ContinuousClock.Instant) async throws -> Ready {
        let previous = generation
        generation += 1
        let current = generation
        await retireWorkers()
        await transport.retire(generation: previous)
        try Task.checkCancellation()
        guard !retired, generation == current else { throw RemoteHostSessionError.obsoleteGeneration }
        state = .connecting
        await publish(.connecting, current)
        let attempt = RemoteHandshakeAttempt(transport: transport, generation: current, deadline: deadline,
            expectedAccount: expectedAccount, expectedEpoch: expectedEpoch) { [weak self] failed, reason in
            await self?.transportFailed(generation: failed, reason: reason)
        }
        self.attempt = attempt
        do {
            let handshake = try await attempt.run()
            try Task.checkCancellation()
            guard !retired, generation == current else { throw RemoteHostSessionError.obsoleteGeneration }
            try handshake.validate(expectedAccount: expectedAccount, expectedEpoch: expectedEpoch)
            expectedAccount = handshake.account
            expectedEpoch = handshake.epoch
            let ready = Ready(generation: current, handshake: handshake)
            self.attempt = nil
            connectionTask = nil
            state = .ready(ready)
            scheduleIdleRetirement()
            await publish(.connected, current)
            return ready
        } catch {
            await transport.retire(generation: current)
            if generation == current { self.attempt = nil }
            throw error
        }
    }

    private func retireAttempt() async {
        let previous = generation
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        await attempt?.cancel()
        attempt = nil
        await transport.retire(generation: previous)
    }

    static func reason(for error: Error) -> SSHConnectionFailureReason {
        if let error = error as? RemoteHostSessionError {
            switch error {
            case .failed(let reason): return reason
            case .invalidHandshake: return .compatibility(error.localizedDescription)
            case .retired, .obsoleteGeneration: return .transport(error.localizedDescription)
            }
        }
        if error is OperationCompatibilityError { return .compatibility(String(describing: error)) }
        if let trust = error as? SSHHostTrustError {
            switch trust {
            case .hostKeyChanged, .hostKeyRejected: return .hostKeyChanged
            default: break
            }
        }
        if case PowerShellChannelError.timeout = error { return .timedOut }
        let message = (error as? PowerShellChannelError)?.failureReason ?? error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("host key verification failed") || lower.contains("host identification has changed") { return .hostKeyChanged }
        if lower.contains("permission denied (publickey") || lower.contains("authentication failed") { return .authentication(message) }
        return .transport(message)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
