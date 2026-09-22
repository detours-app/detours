import Foundation

extension FileListViewController {
    func scheduleRemoteRefreshRecovery(for directory: Location) {
        let attempt = remoteRefreshRecoveryAttempts[directory, default: 0]
        guard attempt < 3, !isShutDown else { return }
        remoteRefreshRecoveryAttempts[directory] = attempt + 1
        remoteRefreshRecoveryTasks[directory]?.cancel()
        let epoch = refreshScheduler.epoch
        remoteRefreshRecoveryTasks[directory] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 500_000_000)
            } catch { return }
            guard let self, !Task.isCancelled, !isShutDown,
                  refreshScheduler.epoch == epoch,
                  paneHasRefreshableListing(directory) else { return }
            remoteRefreshRecoveryTasks.removeValue(forKey: directory)
            refreshScheduler.submitListingRefresh(directory: directory, cause: .retry)
        }
    }

    func cancelRemoteRefreshRecovery(for directory: Location? = nil) {
        if let directory {
            remoteRefreshRecoveryTasks.removeValue(forKey: directory)?.cancel()
            remoteRefreshRecoveryAttempts.removeValue(forKey: directory)
        } else {
            for task in remoteRefreshRecoveryTasks.values { task.cancel() }
            remoteRefreshRecoveryTasks.removeAll()
            remoteRefreshRecoveryAttempts.removeAll()
        }
    }

    func recoverRemoteListingAfterReconnect() {
        guard !isShutDown, !isNavigationLoadInFlight,
              let root = currentRemoteLocation, let provider = currentRemoteProvider else { return }
        cancelRemoteRefreshRecovery()
        let directories = materializedListingDirectories()
        startWatching(root, provider: provider)
        for directory in directories {
            if directory != root { watchExpandedDirectory(directory) }
            refreshScheduler.submitListingRefresh(directory: directory, cause: .watcher)
        }
    }
}
