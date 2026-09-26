import Foundation

actor RemoteReadinessWaiter {
    private var continuation: CheckedContinuation<RemoteHostSession.Ready, Error>?
    private var result: Result<RemoteHostSession.Ready, Error>?

    func wait(for shared: Task<RemoteHostSession.Ready, Error>) async throws -> RemoteHostSession.Ready {
        Task { [weak self] in
            let result = await shared.result
            await self?.finish(result)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<RemoteHostSession.Ready, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
