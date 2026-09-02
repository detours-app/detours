import Foundation

/// Writing into a pipe whose reader has gone away raises SIGPIPE, which ends the whole process
/// without a crash report. Every SSH pipe writer touches this once so a dead ssh becomes an
/// error the caller can show, not a silent quit.
enum BrokenPipe {
    static let ignored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}
