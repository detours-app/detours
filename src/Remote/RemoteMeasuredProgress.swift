import Foundation

final class RemoteMeasuredProgress: @unchecked Sendable {
    enum Source: Hashable { case sent, remote }
    private let lock = NSLock()
    private var measuredBytes: [Source: UInt64] = [:]
    private var advanced: ContinuousClock.Instant
    private var failure: Error?

    init(startedAt: ContinuousClock.Instant = .now) { advanced = startedAt }

    func record(_ bytes: UInt64, at now: ContinuousClock.Instant = .now, source: Source = .remote) {
        lock.withLock {
            if bytes > measuredBytes[source, default: 0] { measuredBytes[source] = bytes; advanced = now }
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
