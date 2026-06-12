import Foundation

struct RemoteWatcherPollSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Hashable, Sendable {
        let location: Location
        let isDirectory: Bool
        let fileSize: Int64?
        let modificationMilliseconds: Int64
    }

    let entries: Set<Entry>

    init(entries: [LoadedFileEntry]) {
        self.entries = Set(entries.map { entry in
            Entry(
                location: entry.location,
                isDirectory: entry.isDirectory,
                fileSize: entry.fileSize,
                modificationMilliseconds: Int64(entry.contentModificationDate.timeIntervalSince1970 * 1_000)
            )
        })
    }
}

actor RemoteWatcherPollFallback {
    typealias SnapshotLoader = @Sendable () async throws -> [LoadedFileEntry]

    private struct PollRegistration {
        let command: String
        let task: Task<Void, Never>
    }

    static let defaultPollIntervalNanoseconds: UInt64 = 10_000_000_000

    private let pollIntervalNanoseconds: UInt64
    private var registrations: [FileProviderWatch: PollRegistration] = [:]

    init(pollIntervalNanoseconds: UInt64 = RemoteWatcherPollFallback.defaultPollIntervalNanoseconds) {
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func start(
        watch: FileProviderWatch,
        inotifyLimitCommand command: String,
        loadSnapshot: @escaping SnapshotLoader,
        onChange: @escaping @Sendable (Location) -> Void
    ) {
        stop(watch)

        let task = Task {
            var previous = try? await loadSnapshot().snapshot
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                if Task.isCancelled { break }

                guard let next = try? await loadSnapshot().snapshot else { continue }
                if let previousSnapshot = previous, previousSnapshot != next {
                    onChange(watch.location)
                }
                previous = next
            }
        }

        registrations[watch] = PollRegistration(command: command, task: task)
    }

    func stop(_ watch: FileProviderWatch) {
        registrations.removeValue(forKey: watch)?.task.cancel()
    }

    func dismissInotifyBanner() {
        stopAll()
    }

    func markLimitRaised() {
        stopAll()
    }

    func inotifyLimitCommand(for watch: FileProviderWatch) -> String? {
        registrations[watch]?.command
    }

    var activeWatchCount: Int {
        registrations.count
    }

    private func stopAll() {
        for registration in registrations.values {
            registration.task.cancel()
        }
        registrations.removeAll()
    }
}

private extension Array where Element == LoadedFileEntry {
    var snapshot: RemoteWatcherPollSnapshot {
        RemoteWatcherPollSnapshot(entries: self)
    }
}
