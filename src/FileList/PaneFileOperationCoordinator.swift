import AppKit

/// The single app-facing gateway for user file operations that can affect a
/// pane listing. It opens a UUID-keyed hold on every matching pane scheduler
/// before the operation starts, submits the operation's result while the
/// holds are still active, and closes them in guaranteed cleanup, so no
/// watcher event can apply an intermediate filesystem state between an
/// operation's start and its result refresh.
@MainActor
final class PaneFileOperationCoordinator {
    static let shared = PaneFileOperationCoordinator()

    private struct Registration {
        weak var scheduler: PaneRefreshScheduler?
        let displaysDirectory: @MainActor (Location) -> Bool
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]

    func register(
        scheduler: PaneRefreshScheduler,
        displaysDirectory: @escaping @MainActor (Location) -> Bool
    ) {
        registrations[ObjectIdentifier(scheduler)] = Registration(
            scheduler: scheduler,
            displaysDirectory: displaysDirectory
        )
    }

    func unregister(scheduler: PaneRefreshScheduler) {
        registrations.removeValue(forKey: ObjectIdentifier(scheduler))
    }

    /// Live schedulers whose panes display one of the affected directories.
    private func matchingSchedulers(for directories: Set<Location>) -> [PaneRefreshScheduler] {
        var matched: [PaneRefreshScheduler] = []
        for (key, registration) in registrations {
            guard let scheduler = registration.scheduler else {
                registrations.removeValue(forKey: key)
                continue
            }
            if directories.contains(where: { registration.displaysDirectory($0) }) {
                matched.append(scheduler)
            }
        }
        return matched
    }

    /// Handle passed to `route` for submitting result refreshes while the
    /// operation's holds are still open.
    struct Transaction {
        let id: UUID
        fileprivate let coordinator: PaneFileOperationCoordinator

        /// Submits an operation-result refresh to every pane displaying
        /// `directory`.
        @MainActor
        func submitRefresh(
            directory: Location,
            policy: PaneRefreshResultPolicy? = nil,
            completion: (() -> Void)? = nil
        ) {
            for scheduler in coordinator.matchingSchedulers(for: [directory]) {
                scheduler.submitListingRefresh(
                    directory: directory,
                    cause: .operation,
                    policy: policy,
                    completion: completion
                )
            }
        }

        /// Submits an operation-result refresh to one specific pane scheduler
        /// (destination-pane policies differ from source panes).
        @MainActor
        func submitRefresh(
            to scheduler: PaneRefreshScheduler,
            directory: Location,
            policy: PaneRefreshResultPolicy? = nil,
            completion: (() -> Void)? = nil
        ) {
            scheduler.submitListingRefresh(
                directory: directory,
                cause: .operation,
                policy: policy,
                completion: completion
            )
        }
    }

    /// Runs one listing-affecting operation as a transaction:
    /// 1. opens holds on every scheduler displaying an affected directory,
    /// 2. performs the operation,
    /// 3. on success, lets `route` submit result intents while holds are open,
    /// 4. closes the holds in guaranteed cleanup (an unsuccessful close still
    ///    flushes watcher work retained under the hold).
    @discardableResult
    func perform<T>(
        affecting directories: Set<Location>,
        operation: @MainActor () async throws -> T,
        route: (@MainActor (T, Transaction) -> Void)? = nil
    ) async rethrows -> T {
        let id = UUID()
        let normalized = Set(directories.map(PaneRefreshScheduler.normalizedDirectory))
        let held = matchingSchedulers(for: normalized)
        for scheduler in held {
            scheduler.openOperationHold(id)
        }
        defer {
            for scheduler in held {
                scheduler.closeOperationHold(id)
            }
        }

        let result = try await operation()
        route?(result, Transaction(id: id, coordinator: self))
        return result
    }
}
