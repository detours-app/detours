import Foundation

enum RemoteRefreshReason: Hashable, Sendable {
    case manual
    case mutation
    case watch
    case retry
}

struct RemoteRefreshRequest: Sendable {
    let directory: Location
    let reasons: Set<RemoteRefreshReason>
    let preferredResultLocations: Set<Location>
    let generation: UInt64
}

struct RemoteRefreshSnapshot: Sendable {
    let request: RemoteRefreshRequest
    let entries: [LoadedFileEntry]
}

enum RemoteRefreshCoordinatorError: LocalizedError {
    case providerUnavailable

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return "The remote connection is unavailable."
        }
    }
}

@MainActor
final class RemoteRefreshCoordinator {
    typealias FetchHandler = (RemoteRefreshRequest) async throws -> [LoadedFileEntry]
    typealias ApplyHandler = (RemoteRefreshSnapshot) -> Void
    typealias FailureHandler = (RemoteRefreshRequest, any Error) -> Void

    private struct DirectoryState {
        var nextGeneration: UInt64 = 0
        var lastAppliedGeneration: UInt64 = 0
        var isFetching = false
        var needsFollowUp = false
        var pendingReasons: Set<RemoteRefreshReason> = []
        var pendingPreferredResults: Set<Location> = []
        var debounceTask: Task<Void, Never>?
    }

    private let debounceNanoseconds: UInt64
    private let fetch: FetchHandler
    private let apply: ApplyHandler
    private let handleFailure: FailureHandler
    private var states: [Location: DirectoryState] = [:]

    init(
        debounceInterval: TimeInterval = 0.1,
        fetch: @escaping FetchHandler,
        apply: @escaping ApplyHandler,
        handleFailure: @escaping FailureHandler
    ) {
        debounceNanoseconds = UInt64(max(0, debounceInterval) * 1_000_000_000)
        self.fetch = fetch
        self.apply = apply
        self.handleFailure = handleFailure
    }

    func requestRefresh(
        affectedLocation: Location,
        isDirectory: Bool = true,
        reason: RemoteRefreshReason,
        preferredResultLocations: Set<Location> = []
    ) {
        guard case .remote = affectedLocation else { return }
        let directory = Self.normalizedDirectory(
            for: affectedLocation,
            isDirectory: isDirectory
        )
        var state = states[directory] ?? DirectoryState()
        state.nextGeneration &+= 1
        state.pendingReasons.insert(reason)
        state.pendingPreferredResults.formUnion(preferredResultLocations)

        if state.isFetching {
            state.needsFollowUp = true
            states[directory] = state
            return
        }

        state.debounceTask?.cancel()
        state.debounceTask = makeDebounceTask(for: directory)
        states[directory] = state
    }

    func cancelAll() {
        for state in states.values {
            state.debounceTask?.cancel()
        }
        states.removeAll()
    }

    static func normalizedDirectory(
        for affectedLocation: Location,
        isDirectory: Bool
    ) -> Location {
        let candidate = isDirectory
            ? affectedLocation
            : affectedLocation.deletingLastPathComponent()
        switch candidate {
        case .local(let url):
            return .local(url.standardizedFileURL)
        case .remote(let hostID, let path):
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            return .remote(hostID: hostID, path: normalizedPath)
        }
    }

    private func makeDebounceTask(for directory: Location) -> Task<Void, Never> {
        let delay = debounceNanoseconds
        return Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self?.beginFetch(for: directory)
        }
    }

    private func beginFetch(for directory: Location) {
        guard var state = states[directory], !state.isFetching else { return }
        state.debounceTask = nil
        state.isFetching = true
        state.needsFollowUp = false
        let request = RemoteRefreshRequest(
            directory: directory,
            reasons: state.pendingReasons,
            preferredResultLocations: state.pendingPreferredResults,
            generation: state.nextGeneration
        )
        state.pendingReasons.removeAll()
        state.pendingPreferredResults.removeAll()
        states[directory] = state

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result: Result<[LoadedFileEntry], any Error>
            do {
                result = .success(try await fetch(request))
            } catch {
                result = .failure(error)
            }
            finishFetch(request: request, result: result)
        }
    }

    private func finishFetch(
        request: RemoteRefreshRequest,
        result: Result<[LoadedFileEntry], any Error>
    ) {
        guard var state = states[request.directory] else { return }
        state.isFetching = false

        if request.generation >= state.nextGeneration,
           request.generation >= state.lastAppliedGeneration {
            switch result {
            case .success(let entries):
                state.lastAppliedGeneration = request.generation
                apply(RemoteRefreshSnapshot(request: request, entries: entries))
            case .failure(let error):
                handleFailure(request, error)
            }
        }

        let shouldFetchAgain = state.needsFollowUp || !state.pendingReasons.isEmpty
        state.needsFollowUp = false
        if shouldFetchAgain {
            state.debounceTask?.cancel()
            state.debounceTask = makeDebounceTask(for: request.directory)
        }
        states[request.directory] = state
    }
}
