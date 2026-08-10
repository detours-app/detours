import Darwin
import Foundation
import os.log

/// Raises how many files the app may hold open at once.
///
/// A GUI app inherits its limits from launchd, and the soft limit that arrives
/// is 256. Detours holds a descriptor open for every directory it watches, and
/// two panes with several tabs and a few expanded folders each get through them
/// quickly. Past the limit a watch silently fails to open and that folder
/// simply stops noticing changes, which reads as Detours being stale rather
/// than as an error.
///
/// The hard limit is normally unlimited, so the app can just ask. The kernel
/// still caps any single process, so the request is clamped to that.
enum FileDescriptorLimit {
    private static let logger = Logger(subsystem: "com.detours", category: "limits")

    /// Comfortably more than a heavily expanded window needs, and far below the
    /// kernel's per-process ceiling.
    static let desired: rlim_t = 8_192

    @discardableResult
    static func raiseSoftLimit(to target: rlim_t = desired) -> rlim_t? {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            logger.warning("Could not read the open-file limit: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        guard let ceiling = perProcessCeiling() else { return nil }

        // The unlimited hard limit is not exposed by name in Swift, so it is
        // spelled out: an unlimited hard limit still leaves the kernel's
        // per-process cap as the real ceiling.
        let unlimited = rlim_t.max
        let hardCeiling = limits.rlim_max == unlimited ? ceiling : min(limits.rlim_max, ceiling)
        let wanted = min(target, hardCeiling)
        guard wanted > limits.rlim_cur else { return limits.rlim_cur }

        var raised = limits
        raised.rlim_cur = wanted
        guard setrlimit(RLIMIT_NOFILE, &raised) == 0 else {
            logger.warning("Could not raise the open-file limit: \(String(cString: strerror(errno)), privacy: .public)")
            return limits.rlim_cur
        }
        logger.info("Raised the open-file limit from \(limits.rlim_cur) to \(wanted)")
        return wanted
    }

    static func currentSoftLimit() -> rlim_t? {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return nil }
        return limits.rlim_cur
    }

    /// The kernel's cap for one process. Asking for more than this fails
    /// outright rather than being clamped, so the request is clamped here.
    private static func perProcessCeiling() -> rlim_t? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.maxfilesperproc", &value, &size, nil, 0) == 0, value > 0 else {
            return nil
        }
        return rlim_t(value)
    }
}
