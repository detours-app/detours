import Foundation

/// Formats listing dates without rebuilding the machinery for every row.
///
/// The table asks each visible row for its formatted date on every redraw, so
/// this sits on the path of drawing a cell. Building a `DateFormatter` is one
/// of Cocoa's more expensive constructions and reading the date formats meant
/// decoding the whole settings blob out of `UserDefaults`, so a listing paid
/// for both once per row per redraw. Both are built once here and reused until
/// the user changes a date format.
final class DateFormatterCache: @unchecked Sendable {
    static let shared = DateFormatterCache()

    private let lock = NSLock()
    private let calendar = Calendar.current
    private var currentYearFormatter: DateFormatter?
    private var otherYearsFormatter: DateFormatter?

    private init() {
        NotificationCenter.default.addObserver(
            forName: SettingsManager.settingsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    /// Formatting happens while the lock is held so a shared `DateFormatter` is
    /// never handed to two callers at once. Rows are formatted on the main
    /// thread, so nothing contends for it in practice.
    func string(for date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatterLocked(for: date).string(from: date)
    }

    /// Drops the cached formatters so the next row picks up new date formats.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        currentYearFormatter = nil
        otherYearsFormatter = nil
    }

    private func formatterLocked(for date: Date) -> DateFormatter {
        // Today's year is read each time rather than cached, so a session left
        // running across New Year keeps bucketing dates correctly. It is cheap
        // next to what this cache exists to avoid.
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            if let existing = currentYearFormatter { return existing }
            let formatter = DateFormatter()
            formatter.dateFormat = Self.settingsSnapshot().dateFormatCurrentYear
            currentYearFormatter = formatter
            return formatter
        }

        if let existing = otherYearsFormatter { return existing }
        let formatter = DateFormatter()
        formatter.dateFormat = Self.settingsSnapshot().dateFormatOtherYears
        otherYearsFormatter = formatter
        return formatter
    }

    private static func settingsSnapshot() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: "Detours.Settings"),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return decoded
    }
}
