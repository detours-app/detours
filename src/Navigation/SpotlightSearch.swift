import Foundation
import os.log

private let logger = Logger(subsystem: "com.detours", category: "spotlight")

/// Manages async NSMetadataQuery for folder search.
/// Results stream in progressively via callback, never blocking the main thread.
@MainActor
final class SpotlightSearch {
    private var query: NSMetadataQuery?
    private var onResults: (([URL]) -> Void)?
    private var currentSearchText: String = ""

    /// Start an async search for folders matching the search text.
    /// Results are delivered progressively via the callback.
    /// Any existing search is cancelled first.
    func search(for searchText: String, onResults: @escaping ([URL]) -> Void) {
        // Cancel any existing query
        cancel()

        guard !searchText.isEmpty else {
            onResults([])
            return
        }

        self.onResults = onResults
        self.currentSearchText = searchText
        logger.info("Starting Spotlight search for: \(searchText)")

        let query = NSMetadataQuery()
        query.searchScopes = [
            NSMetadataQueryLocalComputerScope
        ]

        // Search display name OR filesystem name (finds more matches)
        // Using CONTAINS[cd] for case-insensitive, diacritic-insensitive matching
        // Use kMDItemContentType to exclude system items (calendars, contacts, etc.)
        // public.item is the base type for all files and folders
        query.predicate = NSPredicate(
            format: "(kMDItemDisplayName CONTAINS[cd] %@ OR kMDItemFSName CONTAINS[cd] %@)",
            searchText, searchText
        )

        // Limit results for performance
        query.notificationBatchingInterval = 0.1

        // Observe notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )

        self.query = query
        let started = query.start()
        logger.info("Spotlight query started: \(started)")
    }

    /// Cancel any in-progress search.
    func cancel() {
        query?.stop()
        if let query = query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        }
        query = nil
        onResults = nil
        currentSearchText = ""
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        logger.debug("Spotlight query did update")
        deliverResults()
    }

    @objc private func queryDidFinish(_ notification: Notification) {
        logger.debug("Spotlight query did finish")
        deliverResults()
        // Don't cancel here - keep query alive for live updates if needed
        // For now, cancel after finish since we restart on each keystroke anyway
        cancel()
    }

    private func deliverResults() {
        guard let query = query, let onResults = onResults else { return }

        query.disableUpdates()
        logger.info("Spotlight query returned \(query.resultCount) raw results")

        var urls: [URL] = []
        let maxResults = 100 // Limit to prevent UI overload

        for i in 0..<min(query.resultCount, maxResults) {
            guard let item = query.result(at: i) as? NSMetadataItem else {
                continue
            }

            // Get path - try NSMetadataItemURLKey first (works for iCloud), fall back to kMDItemPath
            let path: String
            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                path = url.path
            } else if let p = item.value(forAttribute: kMDItemPath as String) as? String {
                path = p
            } else {
                continue
            }

            // Skip system paths
            if path.hasPrefix("/System") ||
               path.hasPrefix("/Library") ||
               path.hasPrefix("/private") ||
               path.contains(".app/") ||
               path.contains(".xcodeproj/") ||
               path.contains(".xcworkspace/") ||
               path.contains("node_modules/") ||
               path.contains(".git/") {
                continue
            }

            // Skip hidden files/folders unless setting is enabled
            if !SettingsManager.shared.searchIncludesHidden {
                let hasHiddenComponent = path.split(separator: "/").contains { $0.hasPrefix(".") }
                if hasHiddenComponent {
                    continue
                }
            }

            urls.append(URL(fileURLWithPath: path))
        }

        query.enableUpdates()
        logger.info("Spotlight delivering \(urls.count) filtered results")
        onResults(urls)
    }
}
