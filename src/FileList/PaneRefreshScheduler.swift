import AppKit

enum PaneListingFetchError: LocalizedError {
    case providerUnavailable

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return "The remote connection is unavailable."
        }
    }
}

/// Why a pane listing wants to change. Explicit operation and navigation work
/// starts immediately and absorbs pending watcher work; watcher-only intents
/// debounce per directory.
enum PaneRefreshCause: Hashable, Sendable {
    case operation
    case watcher
    case git
    case crossPane
    case manual
    case retry
}

/// What an explicit operation wants the pane to do once the transaction
/// containing its results applies. The whole policy is atomic: reveal, any
/// required targeted-filter clear, selection, scrolling, activation, focus,
/// and rename startup belong to one eligible transaction.
struct PaneRefreshResultPolicy {
    var preferredResultLocations: Set<Location> = []
    var expandTo: Location?
    /// Explicit operation results outrank the targeted tab's filter; background
    /// causes never clear one.
    var clearsFilterConcealingResults = false
    /// Runs after the transaction that contains the requested items applied
    /// (selection, activation, focus, rename startup).
    var onApplied: (() -> Void)?
}

struct PaneListingRequest {
    let directory: Location
    let causes: Set<PaneRefreshCause>
    let policy: PaneRefreshResultPolicy?
    let epoch: UInt64
    let generation: UInt64
}

struct PaneListingSnapshot {
    let request: PaneListingRequest
    let entries: [LoadedFileEntry]
}

/// Outcome of applying one listing snapshot; tells the scheduler whether the
/// pending result policy was consumed or must ride the next apply.
struct PaneListingApplyOutcome {
    var policyConsumed = true
}

/// One owner per pane for every programmatic listing refresh. All reasons to
/// refresh (finished operations, watcher events, git updates, cross-pane
/// requests, retries) submit typed intents here; the scheduler folds them into
/// per-directory single-flight fetches, gates them behind operation holds, and
/// applies results only when their epoch, directory, and generation still
/// match the pane.
@MainActor
final class PaneRefreshScheduler {
    struct Dependencies {
        var fetch: @MainActor (PaneListingRequest) async throws -> [LoadedFileEntry]
        var apply: @MainActor (PaneListingSnapshot) -> PaneListingApplyOutcome
        var handleFailure: @MainActor (PaneListingRequest, any Error) -> Void
        var applyRowRefreshes: @MainActor ([(item: FileItem, columns: IndexSet)]) -> Void
        var canApplyNow: @MainActor () -> Bool
        var displaysDirectory: @MainActor (Location) -> Bool
    }

    private struct DirectoryState {
        var nextGeneration: UInt64 = 0
        var lastAppliedGeneration: UInt64 = 0
        var isFetching = false
        var needsFollowUp = false
        var pendingCauses: Set<PaneRefreshCause> = []
        /// Latest eligible policy plus everything folded from superseded intents.
        var pendingPolicy: PaneRefreshResultPolicy?
        var pendingCompletions: [() -> Void] = []
        var debounceTask: Task<Void, Never>?
    }

    /// Watcher debounce per directory (matches the historical listing debounce).
    static let watcherDebounce: TimeInterval = 0.1

    private var dependencies: Dependencies?
    private var states: [Location: DirectoryState] = [:]
    private(set) var epoch: UInt64 = 0

    /// Open operation holds. While any hold is open, watcher-cause fetches are
    /// retained instead of started; operation results submitted under a hold
    /// start the moment the hold closes.
    private var activeHolds: Set<UUID> = []
    private var directoriesAwaitingHoldClose: Set<Location> = []

    /// Row-scoped intents batched on the next main-actor turn.
    private var pendingRowRefreshes: [ObjectIdentifier: (item: FileItem, columns: IndexSet)] = [:]
    private var rowFlushScheduled = false

    func configure(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var isConfigured: Bool { dependencies != nil }

    var isRefreshInFlight: Bool {
        states.values.contains { $0.isFetching || $0.debounceTask != nil }
            || !directoriesAwaitingHoldClose.isEmpty
    }

    // MARK: - Navigation epoch

    /// Navigation invalidates all older work: in-flight results become
    /// ineligible, pending policies and completions are dropped.
    func noteNavigation() {
        epoch &+= 1
        for state in states.values {
            state.debounceTask?.cancel()
        }
        states.removeAll()
        directoriesAwaitingHoldClose.removeAll()
        pendingRowRefreshes.removeAll()
    }

    // MARK: - Listing intents

    func submitListingRefresh(
        directory: Location,
        cause: PaneRefreshCause,
        policy: PaneRefreshResultPolicy? = nil,
        completion: (() -> Void)? = nil
    ) {
        let normalized = Self.normalizedDirectory(directory)
        var state = states[normalized] ?? DirectoryState()
        state.nextGeneration &+= 1
        state.pendingCauses.insert(cause)
        if let policy {
            state.pendingPolicy = Self.folded(newer: policy, older: state.pendingPolicy)
        }
        if let completion {
            state.pendingCompletions.append(completion)
        }

        if state.isFetching {
            state.needsFollowUp = true
            states[normalized] = state
            return
        }

        let isBlockedByHold = !activeHolds.isEmpty
        if isBlockedByHold && cause == .watcher {
            // Retained under the hold; folded into the closing operation
            // intent (or flushed by an unsuccessful close).
            directoriesAwaitingHoldClose.insert(normalized)
            states[normalized] = state
            return
        }
        if isBlockedByHold && cause == .operation {
            // Operation results are submitted while holds are still active and
            // start when the hold closes.
            directoriesAwaitingHoldClose.insert(normalized)
            states[normalized] = state
            return
        }

        state.debounceTask?.cancel()
        // Explicit work absorbs pending watcher causes and starts immediately;
        // watcher-only intents keep the per-directory debounce.
        state.debounceTask = makeDebounceTask(
            for: normalized,
            delay: state.pendingCauses == [.watcher] ? Self.watcherDebounce : 0
        )
        states[normalized] = state
    }

    /// Newer intents win; older preferred results, filter behavior, and
    /// completions fold into the follow-up.
    private static func folded(
        newer: PaneRefreshResultPolicy,
        older: PaneRefreshResultPolicy?
    ) -> PaneRefreshResultPolicy {
        guard let older else { return newer }
        var merged = newer
        merged.preferredResultLocations.formUnion(older.preferredResultLocations)
        merged.clearsFilterConcealingResults =
            newer.clearsFilterConcealingResults || older.clearsFilterConcealingResults
        if merged.expandTo == nil {
            merged.expandTo = older.expandTo
        }
        if let olderAction = older.onApplied {
            let newerAction = merged.onApplied
            merged.onApplied = {
                olderAction()
                newerAction?()
            }
        }
        return merged
    }

    // MARK: - Operation holds

    func openOperationHold(_ id: UUID) {
        activeHolds.insert(id)
    }

    func closeOperationHold(_ id: UUID) {
        guard activeHolds.remove(id) != nil else { return }
        guard activeHolds.isEmpty else { return }
        let directories = directoriesAwaitingHoldClose
        directoriesAwaitingHoldClose.removeAll()
        for directory in directories {
            guard var state = states[directory], !state.isFetching else { continue }
            state.debounceTask?.cancel()
            // The closing operation intent starts immediately and carries any
            // watcher causes retained under the hold.
            state.debounceTask = makeDebounceTask(
                for: directory,
                delay: state.pendingCauses == [.watcher] ? Self.watcherDebounce : 0
            )
            states[directory] = state
        }
    }

    var hasOpenOperationHold: Bool { !activeHolds.isEmpty }

    // MARK: - Row intents

    func submitRowRefresh(item: FileItem, columns: IndexSet) {
        let id = ObjectIdentifier(item)
        if var existing = pendingRowRefreshes[id] {
            existing.columns.formUnion(columns)
            pendingRowRefreshes[id] = existing
        } else {
            pendingRowRefreshes[id] = (item, columns)
        }
        guard !rowFlushScheduled else { return }
        rowFlushScheduled = true
        Task { @MainActor [weak self] in
            self?.flushRowRefreshes()
        }
    }

    private func flushRowRefreshes() {
        rowFlushScheduled = false
        guard let dependencies, dependencies.canApplyNow() else {
            pendingRowRefreshes.removeAll()
            return
        }
        let batch = Array(pendingRowRefreshes.values)
        pendingRowRefreshes.removeAll()
        guard !batch.isEmpty else { return }
        dependencies.applyRowRefreshes(batch)
    }

    // MARK: - Fetch machinery

    /// Starts any retained work once the pane's outline becomes available
    /// (lazy tabs, session restore).
    func activate() {
        for (directory, state) in states where !state.isFetching && state.debounceTask == nil {
            guard !state.pendingCauses.isEmpty else { continue }
            guard !directoriesAwaitingHoldClose.contains(directory) else { continue }
            var updated = state
            updated.debounceTask = makeDebounceTask(for: directory, delay: 0)
            states[directory] = updated
        }
    }

    private func makeDebounceTask(for directory: Location, delay: TimeInterval) -> Task<Void, Never> {
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        return Task { @MainActor [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            self?.beginFetch(for: directory)
        }
    }

    private func beginFetch(for directory: Location) {
        guard var state = states[directory], !state.isFetching else { return }
        state.debounceTask = nil
        states[directory] = state

        // A hold opened after this fetch was scheduled still wins: nothing
        // fetches or applies between a transaction's open and its result.
        guard activeHolds.isEmpty else {
            directoriesAwaitingHoldClose.insert(directory)
            return
        }

        guard let dependencies else { return }
        guard dependencies.canApplyNow() else {
            // Pre-view-load: retain only the latest eligible intent; `activate()`
            // replays it when the outline exists.
            return
        }
        guard dependencies.displaysDirectory(directory) else { return }

        state.isFetching = true
        state.needsFollowUp = false
        let request = PaneListingRequest(
            directory: directory,
            causes: state.pendingCauses,
            policy: state.pendingPolicy,
            epoch: epoch,
            generation: state.nextGeneration
        )
        state.pendingCauses.removeAll()
        states[directory] = state

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result: Result<[LoadedFileEntry], any Error>
            do {
                result = .success(try await dependencies.fetch(request))
            } catch {
                result = .failure(error)
            }
            self.finishFetch(request: request, result: result)
        }
    }

    private func finishFetch(
        request: PaneListingRequest,
        result: Result<[LoadedFileEntry], any Error>
    ) {
        guard request.epoch == epoch else { return }
        guard var state = states[request.directory] else { return }
        state.isFetching = false

        let isNewestEligible = request.generation >= state.nextGeneration
            && request.generation >= state.lastAppliedGeneration
        if isNewestEligible, let dependencies, dependencies.displaysDirectory(request.directory) {
            switch result {
            case .success(let entries):
                state.lastAppliedGeneration = request.generation
                let completions = state.pendingCompletions
                state.pendingCompletions = []
                states[request.directory] = state
                let outcome = dependencies.apply(
                    PaneListingSnapshot(request: request, entries: entries)
                )
                state = states[request.directory] ?? state
                state.isFetching = false
                if outcome.policyConsumed {
                    if state.pendingPolicy != nil,
                       request.generation >= state.nextGeneration {
                        state.pendingPolicy = nil
                    }
                    for completion in completions {
                        completion()
                    }
                } else {
                    // The snapshot did not contain the requested results; the
                    // policy and completions ride the follow-up or retry.
                    state.pendingCompletions = completions + state.pendingCompletions
                }
            case .failure(let error):
                // Failure applies nothing and consumes no policy or completion;
                // a later retry runs them after a successful apply.
                states[request.directory] = state
                dependencies.handleFailure(request, error)
                state = states[request.directory] ?? state
                state.isFetching = false
            }
        }

        let shouldFetchAgain = state.needsFollowUp || !state.pendingCauses.isEmpty
        state.needsFollowUp = false
        if shouldFetchAgain, activeHolds.isEmpty {
            state.debounceTask?.cancel()
            state.debounceTask = makeDebounceTask(
                for: request.directory,
                delay: state.pendingCauses == [.watcher] ? Self.watcherDebounce : 0
            )
        } else if shouldFetchAgain {
            directoriesAwaitingHoldClose.insert(request.directory)
        }
        states[request.directory] = state
    }

    // MARK: - Lifecycle

    func cancelAll() {
        for state in states.values {
            state.debounceTask?.cancel()
        }
        states.removeAll()
        directoriesAwaitingHoldClose.removeAll()
        pendingRowRefreshes.removeAll()
    }

    static func normalizedDirectory(_ location: Location) -> Location {
        switch location {
        case .local(let url):
            return .local(url.standardizedFileURL)
        case .remote(let hostID, let path):
            return .remote(
                hostID: hostID,
                path: URL(fileURLWithPath: path).standardizedFileURL.path
            )
        }
    }
}
