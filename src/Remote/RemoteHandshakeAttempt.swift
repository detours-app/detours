import Foundation
import RemoteOperationSupport

actor RemoteHandshakeAttempt {
    private let transport: any RemoteHostSessionTransport
    private let generation: UInt64
    private let deadline: ContinuousClock.Instant
    private let onFailure: @Sendable (UInt64, SSHConnectionFailureReason) async -> Void
    private var continuation: CheckedContinuation<OperationHandshake, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cancelled = false

    init(transport: any RemoteHostSessionTransport, generation: UInt64, deadline: ContinuousClock.Instant,
         onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) {
        self.transport = transport
        self.generation = generation
        self.deadline = deadline
        self.onFailure = onFailure
    }

    func run() async throws -> OperationHandshake {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                worker = Task {
                    do {
                        let handshake = try await transport.handshake(generation: generation, onFailure: onFailure)
                        _ = finish(.success(handshake))
                    } catch { _ = finish(.failure(error)) }
                }
                timer = Task {
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    if finish(.failure(RemoteHostSessionError.failed(.timedOut))) {
                        await transport.retire(generation: generation)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() async {
        cancelled = true
        _ = finish(.failure(CancellationError()))
        await transport.retire(generation: generation)
    }

    private func finish(_ result: Result<OperationHandshake, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        worker?.cancel()
        timer?.cancel()
        worker = nil
        timer = nil
        continuation.resume(with: result)
        return true
    }
}
