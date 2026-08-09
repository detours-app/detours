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

    static func start() -> Timestamp {
        Timestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    struct Timestamp {
        let nanoseconds: UInt64

        var elapsedMilliseconds: String {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- nanoseconds
            return String(format: "%.1f", Double(elapsed) / 1_000_000)
        }
    }
}
