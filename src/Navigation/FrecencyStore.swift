import CoreServices
import Foundation
import os.log

private let logger = Logger(subsystem: "com.detour", category: "frecency")

/// Persists directory visit history and calculates frecency scores.
/// Frecency = frequency + recency - ranks items by combining visit count with time decay.
@MainActor
final class FrecencyStore {
    static let shared = FrecencyStore()

    private var entries: [String: FrecencyEntry] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 2.0

    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let detourDir = appSupport.appendingPathComponent("Detour")
        try? FileManager.default.createDirectory(at: detourDir, withIntermediateDirectories: true)
        return detourDir.appendingPathComponent("frecency.json")
    }()

    private init() {
        load()
    }

    // MARK: - Public API

    /// Record a visit to a directory. Call this on every navigation.
    func recordVisit(_ url: URL) {
        let path = url.standardizedFileURL.path

        // Only track directories
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        if var entry = entries[path] {
            entry.visitCount += 1
            entry.lastVisit = Date()
            entries[path] = entry
        } else {
            entries[path] = FrecencyEntry(path: path, visitCount: 1, lastVisit: Date())
        }

        scheduleSave()
    }

    /// Get top directories matching a query, sorted by frecency score.
    /// Empty query returns top directories by frecency.
    /// Non-empty query searches filesystem + frecency entries.
    func topDirectories(matching query: String, limit: Int = 10) -> [URL] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)

        // Empty query: return frecent directories only
        if trimmedQuery.isEmpty {
            return topFrecent(limit: limit)
        }

        // Expand ~ to home directory
        let expandedQuery: String
        if trimmedQuery.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expandedQuery = home + trimmedQuery.dropFirst()
        } else {
            expandedQuery = trimmedQuery
        }

        // If query looks like an absolute path, check if it exists
        if expandedQuery.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expandedQuery, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return [URL(fileURLWithPath: expandedQuery)]
            }
        }

        // Search filesystem + frecency entries
        var results: [URL: Double] = [:]

        // Add matching frecent entries with their scores
        let queryLower = expandedQuery.lowercased()
        for (path, entry) in entries {
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if lastComponent.contains(queryLower) || path.lowercased().contains(queryLower) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    results[URL(fileURLWithPath: path)] = frecencyScore(for: entry)
                }
            }
        }

        // Search filesystem
        let filesystemMatches = searchFilesystem(query: expandedQuery, limit: limit * 2)
        for url in filesystemMatches {
            if results[url] == nil {
                results[url] = 0.0
            }
        }

        // Sort by score descending, take top N
        let sorted = results.sorted { $0.value > $1.value }
        return Array(sorted.prefix(limit).map { $0.key })
    }

    /// Return top frecent directories (for empty query)
    private func topFrecent(limit: Int) -> [URL] {
        var scored: [(URL, Double)] = []

        for (path, entry) in entries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            scored.append((URL(fileURLWithPath: path), frecencyScore(for: entry)))
        }

        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(limit).map { $0.0 })
    }

    /// Search filesystem for directories matching query using Spotlight
    private func searchFilesystem(query: String, limit: Int) -> [URL] {
        let queryLower = query.lowercased()

        // Use Spotlight MDQuery for fast search
        // Query: folders whose name contains the search term, excluding hidden and system paths
        let escaped = queryLower.replacingOccurrences(of: "'", with: "\\'")
        let queryString = "kMDItemContentType == 'public.folder' && kMDItemDisplayName == '*\(escaped)*'cd"

        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else {
            logger.error("Failed to create MDQuery")
            return []
        }

        // Execute synchronously - this is fast because Spotlight index is pre-built
        let options = CFOptionFlags(kMDQuerySynchronous.rawValue)
        guard MDQueryExecute(mdQuery, options) else {
            logger.error("MDQuery execution failed")
            return []
        }

        var results: [URL] = []
        let count = MDQueryGetResultCount(mdQuery)

        for i in 0..<count {
            guard let rawPtr = MDQueryGetResultAtIndex(mdQuery, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(rawPtr).takeUnretainedValue()

            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }

            // Skip hidden paths and system directories
            if path.contains("/.") ||
               path.hasPrefix("/System") ||
               path.hasPrefix("/Library") ||
               path.contains("/Library/") ||
               path.hasPrefix("/private") ||
               path.contains(".app/") ||
               path.contains(".xcodeproj/") ||
               path.contains(".xcworkspace/") ||
               path.contains("node_modules/") ||
               path.contains(".git/") {
                continue
            }

            results.append(URL(fileURLWithPath: path))
            if results.count >= limit {
                break
            }
        }

        return results
    }

    /// Check if a directory is "frecent" (high score) - used for showing star icon
    func isFrecent(_ url: URL) -> Bool {
        guard let entry = entries[url.standardizedFileURL.path] else {
            return false
        }
        return frecencyScore(for: entry) >= 3.0
    }

    // MARK: - Frecency Scoring

    /// Calculate frecency score: visitCount * recencyWeight
    func frecencyScore(for entry: FrecencyEntry) -> Double {
        let weight = recencyWeight(for: entry.lastVisit)
        return Double(entry.visitCount) * weight
    }

    /// Recency weight based on time buckets
    private func recencyWeight(for date: Date) -> Double {
        let age = Date().timeIntervalSince(date)
        let hours = age / 3600

        if hours < 4 {
            return 1.0
        } else if hours < 24 {
            return 0.7
        } else if hours < 24 * 7 {
            return 0.5
        } else if hours < 24 * 30 {
            return 0.3
        } else {
            return 0.1
        }
    }

    // MARK: - Fuzzy Matching

    /// Fuzzy match: characters must appear in order but not consecutively.
    /// Case-insensitive.
    private func fuzzyMatch(query: String, target: String) -> Bool {
        let queryLower = query.lowercased()
        let targetLower = target.lowercased()

        var queryIndex = queryLower.startIndex
        var targetIndex = targetLower.startIndex

        while queryIndex < queryLower.endIndex && targetIndex < targetLower.endIndex {
            if queryLower[queryIndex] == targetLower[targetIndex] {
                queryIndex = queryLower.index(after: queryIndex)
            }
            targetIndex = targetLower.index(after: targetIndex)
        }

        return queryIndex == queryLower.endIndex
    }

    // MARK: - Persistence

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            logger.info("No frecency data found at \(self.storageURL.path)")
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loadedEntries = try decoder.decode([FrecencyEntry].self, from: data)
            entries = Dictionary(uniqueKeysWithValues: loadedEntries.map { ($0.path, $0) })
            pruneOldEntries()
            logger.info("Loaded \(self.entries.count) frecency entries")
        } catch {
            logger.error("Failed to load frecency data: \(error.localizedDescription)")
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(Array(entries.values))
            try data.write(to: storageURL, options: .atomic)
            logger.debug("Saved \(self.entries.count) frecency entries")
        } catch {
            logger.error("Failed to save frecency data: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.save()
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
    }

    /// Remove stale entries: score < 0.1 and no visits in 90 days
    private func pruneOldEntries() {
        let cutoffDate = Date().addingTimeInterval(-90 * 24 * 3600)
        let before = entries.count

        entries = entries.filter { _, entry in
            let score = frecencyScore(for: entry)
            let isRecent = entry.lastVisit > cutoffDate
            return score >= 0.1 || isRecent
        }

        let removed = before - entries.count
        if removed > 0 {
            logger.info("Pruned \(removed) stale frecency entries")
        }
    }

    // MARK: - Testing Support

    /// Clear all entries (for testing)
    func clearAll() {
        entries.removeAll()
    }

    /// Get entry for path (for testing)
    func entry(for path: String) -> FrecencyEntry? {
        entries[path]
    }
}

// MARK: - FrecencyEntry

struct FrecencyEntry: Codable {
    let path: String
    var visitCount: Int
    var lastVisit: Date
}
