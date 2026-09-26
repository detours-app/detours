import Foundation

final class RemoteMeasuredProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var measuredBytes: UInt64 = 0
    private var advanced: ContinuousClock.Instant
    private var failure: Error?

    init(startedAt: ContinuousClock.Instant = .now) { advanced = startedAt }

    func record(_ bytes: UInt64, at now: ContinuousClock.Instant = .now) {
        lock.withLock {
            if bytes > measuredBytes { measuredBytes = bytes; advanced = now }
        }
    }

    func fail(_ error: Error) { lock.withLock { failure = error } }

    func check(at now: ContinuousClock.Instant = .now) throws {
        try lock.withLock {
            if let failure { throw failure }
            if advanced.duration(to: now) >= .seconds(30) { throw RemoteProcessWorkerError.timedOut }
        }
    }
}
