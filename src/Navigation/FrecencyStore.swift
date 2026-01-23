import Foundation
import os.log

private let logger = Logger(subsystem: "com.detours", category: "frecency")

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
        let detourDir = appSupport.appendingPathComponent("Detours")
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

        // Note: Filesystem search is now handled by SpotlightSearch (async)
        // This method returns frecency matches only for backward compatibility

        // Sort by score descending, take top N
        let sorted = results.sorted { $0.value > $1.value }
        return Array(sorted.prefix(limit).map { $0.key })
    }

    /// Get frecency matches only (no Spotlight search). Fast, for instant results.
    func frecencyMatches(for query: String, limit: Int = 10) -> [URL] {
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

        // Search frecency entries only (no filesystem search)
        var results: [(URL, Double)] = []
        let queryLower = expandedQuery.lowercased()

        for (path, entry) in entries {
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if lastComponent.contains(queryLower) || path.lowercased().contains(queryLower) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    results.append((URL(fileURLWithPath: path), frecencyScore(for: entry)))
                }
            }
        }

        // Sort by score descending, take top N
        results.sort { $0.1 > $1.1 }
        return Array(results.prefix(limit).map { $0.0 })
    }

    /// Merge frecency results with Spotlight results.
    /// Folders come first, then files. Within each group, sorted by frecency score.
    func mergeResults(frecency: [URL], spotlight: [URL], limit: Int = 10) -> [URL] {
        var seen = Set<URL>()
        var allResults: [(url: URL, score: Double, isDirectory: Bool)] = []

        // Add frecency results with their scores
        for url in frecency {
            if !seen.contains(url) {
                seen.insert(url)
                let score = entries[url.path].map { frecencyScore(for: $0) } ?? 0.0
                var isDir: ObjCBool = false
                let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                allResults.append((url, score, isDirectory))
            }
        }

        // Add Spotlight results that aren't already in frecency
        for url in spotlight {
            if !seen.contains(url) {
                seen.insert(url)
                let score = entries[url.path].map { frecencyScore(for: $0) } ?? 0.0
                var isDir: ObjCBool = false
                let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                allResults.append((url, score, isDirectory))
            }
        }

        // Sort: folders first, then by score descending
        allResults.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory  // folders come first
            }
            return lhs.score > rhs.score
        }

        return Array(allResults.prefix(limit).map { $0.url })
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

    /// Check if a directory is "frecent" (high score) - used for showing star icon
    func isFrecent(_ url: URL) -> Bool {
        guard let entry = entries[url.standardizedFileURL.path] else {
            return false
        }
        return frecencyScore(for: entry) >= 3.0
    }

    // MARK: - Frecency Scoring

    /// Calculate frecency score: sqrt(visitCount) * recencyWeight
    /// Using sqrt dampens high visit counts so recent locations can compete.
    /// Recency weights are aggressive: recent visits dominate over old frequent ones.
    func frecencyScore(for entry: FrecencyEntry) -> Double {
        let weight = recencyWeight(for: entry.lastVisit)
        return sqrt(Double(entry.visitCount)) * weight
    }

    /// Recency weight based on time buckets - heavily favors recent visits
    private func recencyWeight(for date: Date) -> Double {
        let age = Date().timeIntervalSince(date)
        let hours = age / 3600

        if hours < 4 {
            return 10.0
        } else if hours < 24 {
            return 6.0
        } else if hours < 24 * 7 {
            return 3.0
        } else if hours < 24 * 30 {
            return 1.0
        } else {
            return 0.2
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
