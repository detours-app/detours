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
    /// The directory check runs on a background queue to avoid blocking
    /// the main thread on network volumes.
    func recordVisit(_ url: URL) {
        recordVisit(.local(url))
    }

    func recordVisit(_ location: Location) {
        if case .remote = location {
            recordConfirmedVisit(location)
            return
        }

        guard case .local(let url) = location else { return }
        let path = url.standardizedFileURL.path

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Only track directories
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }

            DispatchQueue.main.async {
                guard let self else { return }

                if var entry = self.entries[path] {
                    entry.visitCount += 1
                    entry.lastVisit = Date()
                    self.entries[path] = entry
                } else {
                    self.entries[path] = FrecencyEntry(location: .local(URL(fileURLWithPath: path)), visitCount: 1, lastVisit: Date())
                }

                self.scheduleSave()
            }
        }
    }

    private func recordConfirmedVisit(_ location: Location) {
        let key = Self.key(for: location)
        if var entry = entries[key] {
            entry.visitCount += 1
            entry.lastVisit = Date()
            entries[key] = entry
        } else {
            entries[key] = FrecencyEntry(location: location, visitCount: 1, lastVisit: Date())
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
        for (_, entry) in entries {
            guard case .local(let entryURL) = entry.location else { continue }
            let path = entryURL.standardizedFileURL.path
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
        frecencyLocationMatches(for: query, includeRemote: false, limit: limit).compactMap(\.localURL)
    }

    func frecencyLocationMatches(
        for query: String,
        remoteHosts: [RemoteHost] = RemoteHostStore.shared.hosts,
        connectedHostIDs: Set<UUID> = [],
        includeRemote: Bool = true,
        limit: Int = 10
    ) -> [QuickNavResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)

        let expandedQuery: String
        if trimmedQuery.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expandedQuery = home + trimmedQuery.dropFirst()
        } else {
            expandedQuery = trimmedQuery
        }

        if !expandedQuery.isEmpty, expandedQuery.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expandedQuery, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return [.local(url: URL(fileURLWithPath: expandedQuery), score: .greatestFiniteMagnitude, isDirectory: true)]
            }
        }

        let queryLower = expandedQuery.lowercased()
        let hostsByID = Dictionary(uniqueKeysWithValues: remoteHosts.map { ($0.id, $0) })
        var results: [QuickNavResult] = []

        for (_, entry) in entries {
            switch entry.location {
            case .local(let entryURL):
                let path = entryURL.standardizedFileURL.path
                guard queryLower.isEmpty || matches(queryLower, path: path, label: nil) else { continue }
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    results.append(.local(url: URL(fileURLWithPath: path), score: frecencyScore(for: entry), isDirectory: true))
                }
            case .remote(let hostID, _):
                guard includeRemote else { continue }
                let host = hostsByID[hostID]
                guard queryLower.isEmpty || matches(queryLower, path: entry.location.path, label: host?.displayName) else { continue }
                results.append(
                    .remote(
                        location: entry.location,
                        host: host,
                        isConnected: connectedHostIDs.contains(hostID),
                        score: frecencyScore(for: entry)
                    )
                )
            }
        }

        results.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.score > rhs.score
        }
        return Array(results.prefix(limit))
    }

    /// Merge frecency results with Spotlight results.
    /// Folders come first, then files. Within each group, sorted by frecency score.
    func mergeResults(frecency: [URL], spotlight: [URL], limit: Int = 10) -> [URL] {
        mergeLocationResults(
            frecency: frecency.map { url in
                var isDir: ObjCBool = false
                let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                let score = entries[Self.key(for: .local(url))].map { frecencyScore(for: $0) } ?? 0.0
                return .local(url: url, score: score, isDirectory: isDirectory)
            },
            spotlight: spotlight,
            limit: limit
        ).compactMap(\.localURL)
    }

    func mergeLocationResults(frecency: [QuickNavResult], spotlight: [URL], limit: Int = 10) -> [QuickNavResult] {
        var seen = Set<Location>()
        var allResults: [QuickNavResult] = []

        for result in frecency {
            if !seen.contains(result.location) {
                seen.insert(result.location)
                allResults.append(result)
            }
        }

        for url in spotlight {
            let location = Location.local(url)
            if !seen.contains(location) {
                seen.insert(location)
                let score = entries[Self.key(for: location)].map { frecencyScore(for: $0) } ?? 0.0
                var isDir: ObjCBool = false
                let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                allResults.append(.local(url: url, score: score, isDirectory: isDirectory))
            }
        }

        allResults.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.score > rhs.score
        }

        return Array(allResults.prefix(limit))
    }

    private func matches(_ query: String, path: String, label: String?) -> Bool {
        let lastComponent = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let lowercasedPath = path.lowercased()
        let lowercasedLabel = label?.lowercased()
        return lastComponent.contains(query) || lowercasedPath.contains(query) || lowercasedLabel?.contains(query) == true
    }

    /// Return top frecent directories (for empty query)
    private func topFrecent(limit: Int) -> [URL] {
        var scored: [(URL, Double)] = []

        for (_, entry) in entries {
            guard case .local(let entryURL) = entry.location else { continue }
            let path = entryURL.standardizedFileURL.path
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
        isFrecent(.local(url))
    }

    func isFrecent(_ location: Location) -> Bool {
        guard let entry = entries[Self.key(for: location)] else {
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
            entries = Dictionary(uniqueKeysWithValues: loadedEntries.map { (Self.key(for: $0.location), $0) })
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
        entries[Self.key(for: .local(URL(fileURLWithPath: path)))] ?? entries[path]
    }

    func entry(for location: Location) -> FrecencyEntry? {
        entries[Self.key(for: location)]
    }

    static func key(for location: Location) -> String {
        switch location {
        case .local(let url):
            return url.standardizedFileURL.path
        case .remote(let hostID, let path):
            let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "remote:\(hostID.uuidString.lowercased()):/\(normalizedPath)"
        }
    }
}

// MARK: - FrecencyEntry

struct FrecencyEntry: Codable {
    let location: Location
    var visitCount: Int
    var lastVisit: Date

    var path: String {
        location.path
    }

    init(location: Location, visitCount: Int, lastVisit: Date) {
        self.location = location
        self.visitCount = visitCount
        self.lastVisit = lastVisit
    }

    init(path: String, visitCount: Int, lastVisit: Date) {
        self.init(location: .local(URL(fileURLWithPath: path)), visitCount: visitCount, lastVisit: lastVisit)
    }

    private enum CodingKeys: String, CodingKey {
        case location
        case path
        case visitCount
        case lastVisit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let location = try container.decodeIfPresent(Location.self, forKey: .location) {
            self.location = location
        } else {
            let path = try container.decode(String.self, forKey: .path)
            self.location = .local(URL(fileURLWithPath: path))
        }
        self.visitCount = try container.decode(Int.self, forKey: .visitCount)
        self.lastVisit = try container.decode(Date.self, forKey: .lastVisit)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(location, forKey: .location)
        try container.encode(path, forKey: .path)
        try container.encode(visitCount, forKey: .visitCount)
        try container.encode(lastVisit, forKey: .lastVisit)
    }
}
