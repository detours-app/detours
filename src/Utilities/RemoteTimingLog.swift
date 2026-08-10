import Foundation
import os.log

/// Stage timings for the remote listing pipeline.
///
/// A remote pane refresh spans a scheduler hop, an SSH round trip, decoding,
/// and an outline apply, but only the total is visible to the user, so a slow
/// refresh gives no clue which stage owns the time. Every stage reports here at
/// debug level, which costs nothing until someone streams it:
///
///     log stream --level debug --predicate 'subsystem == "com.detours" AND category == "remote-timing"'
enum RemoteTimingLog {
    private static let logger = Logger(subsystem: "com.detours", category: "remote-timing")

    static func mark(_ stage: String, _ detail: String = "") {
        logger.debug("\(stage, privacy: .public) \(detail, privacy: .public)")
    }

    static func mark(_ stage: String, since start: Timestamp, _ detail: String = "") {
        logger.debug("\(stage, privacy: .public) ms=\(start.elapsedMilliseconds, privacy: .public) \(detail, privacy: .public)")
    }

    /// One line per user-initiated refresh, kept at notice level so the total is
    /// readable afterwards without a debug stream attached. Streaming the debug
    /// stages costs enough to distort the very timings being measured, so the
    /// headline number has to survive on its own.
    static func total(_ stage: String, since start: Timestamp, _ detail: String = "") {
        logger.notice("\(stage, privacy: .public) ms=\(start.elapsedMilliseconds, privacy: .public) \(detail, privacy: .public)")
    }

    static func start() -> Timestamp {
        Timestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    struct Timestamp {
        let nanoseconds: UInt64

        var elapsed: Double {
            Double(DispatchTime.now().uptimeNanoseconds &- nanoseconds) / 1_000_000
        }

        var elapsedMilliseconds: String {
            String(format: "%.1f", elapsed)
        }
    }
}
