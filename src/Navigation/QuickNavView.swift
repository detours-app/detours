import SwiftUI

/// SwiftUI view for the Cmd-P quick navigation popover.
struct QuickNavView: View {
    @State private var query: String = ""
    @State private var results: [QuickNavResult] = []
    @State private var frecencyResults: [QuickNavResult] = []
    @State private var scopedResults: [URL] = []
    @State private var spotlightResults: [URL] = []
    @State private var selectedIndex: Int = 0
    @State private var spotlightSearch = SpotlightSearch()
    @State private var spotlightDebounce: Task<Void, Never>?
    @State private var scopedSearchTask: Task<Void, Never>?
    @State private var remoteSearchTask: Task<Void, Never>?
    @State private var remoteLiveResults: [QuickNavResult] = []
    @State private var remoteSearchInFlight = false
    @State private var remoteSearchFailed = false
    @FocusState private var isTextFieldFocused: Bool

    var scope: QuickNavScope = .local
    var searchRoots: [URL] = []
    let onSelect: (URL) -> Void
    var onSelectLocation: ((Location, Bool) -> Void)?
    let onReveal: (_ folder: URL, _ itemToSelect: URL) -> Void
    let onDismiss: () -> Void

    private let maxResults = 50
    private let emptyQueryLimit = 12
    private let spotlightDebounceInterval: UInt64 = 150_000_000
    private let remoteSearchCap = 1_000

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            TextField("Quick Open...", text: $query)
                .textFieldStyle(.plain)
                .font(Font(ThemeManager.shared.currentTheme.font(size: 15)))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .focused($isTextFieldFocused)
                .accessibilityIdentifier("quickNavSearchField")
                .onSubmit {
                    if isDisconnectedRemote {
                        reconnect()
                    } else {
                        selectCurrent()
                    }
                }
                .onChange(of: query) { _, newValue in
                    performSearch(newValue)
                }

            Divider()

            scopeHeader

            // Results list
            if isDisconnectedRemote {
                reconnectAffordance
            } else if results.isEmpty && remoteSearchInFlight {
                searchingIndicator
            } else if results.isEmpty && remoteSearchFailed {
                centeredMessage("Search unavailable", systemImage: "exclamationmark.triangle")
            } else if results.isEmpty && !query.isEmpty {
                centeredMessage("No matches", systemImage: nil)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results.indices, id: \.self) { index in
                                let result = results[index]
                                ResultRow(
                                    result: result,
                                    isSelected: index == selectedIndex,
                                    isFrecent: FrecencyStore.shared.isFrecent(result.location)
                                )
                                .id(index)
                                .onTapGesture {
                                    selectedIndex = index
                                    selectCurrent()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 600)
                    .onChange(of: selectedIndex) { _, newIndex in
                        withAnimation {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            // Footer with keyboard hints
            Divider()
            HStack(spacing: 16) {
                Text("↑↓ navigate")
                Text("↵ open")
                Text("⌘↵ reveal")
                Text("⇥ autocomplete")
            }
            .font(Font(ThemeManager.shared.currentTheme.font(size: 12)))
            .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
            .padding(.vertical, 8)
        }
        .frame(width: 900)
        .background(Color(ThemeManager.shared.currentTheme.background))
        .task {
            loadInitialResults()
            // Delay focus slightly to ensure window is ready
            try? await Task.sleep(nanoseconds: 50_000_000)
            isTextFieldFocused = true
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.tab) {
            autocomplete()
            return .handled
        }
        .onKeyPress(.return) {
            if NSEvent.modifierFlags.contains(.command) {
                revealCurrent()
                return .handled
            }
            // Plain Return is handled by onSubmit
            return .ignored
        }
        .onDisappear {
            spotlightDebounce?.cancel()
            scopedSearchTask?.cancel()
            remoteSearchTask?.cancel()
            spotlightSearch.cancel()
        }
    }

    // MARK: - Scope

    private var isRemoteScope: Bool {
        if case .remote = scope { return true }
        return false
    }

    private var remoteHost: RemoteHost? {
        if case .remote(let host, _, _) = scope { return host }
        return nil
    }

    private var remoteProvider: (any FileProvider)? {
        if case .remote(_, let provider, _) = scope { return provider }
        return nil
    }

    private var isDisconnectedRemote: Bool {
        if case .remote(_, _, let isConnected) = scope { return !isConnected }
        return false
    }

    private var scopeHeaderText: String {
        if case .remote(let host, _, _) = scope {
            return "Searching \(host.displayName) - entire host"
        }
        return "This Mac"
    }

    private var scopeHeader: some View {
        HStack(spacing: 6) {
            if isRemoteScope {
                Image(systemName: "globe")
                    .font(.system(size: 11))
            }
            Text(scopeHeaderText)
                .accessibilityIdentifier("quickNavScopeHeader")
            if remoteSearchInFlight {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("quickNavSearchSpinner")
            }
            Spacer()
        }
        .font(Font(ThemeManager.shared.currentTheme.font(size: 11)))
        .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var searchingIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Searching...")
                .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
        }
        .frame(height: 600)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("quickNavSearchingIndicator")
    }

    private func centeredMessage(_ text: String, systemImage: String?) -> some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .light))
            }
            Text(text)
        }
        .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
        .frame(height: 600)
        .frame(maxWidth: .infinity)
    }

    private var reconnectAffordance: some View {
        Button {
            reconnect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                Text("Reconnect to \(remoteHost?.displayName ?? "server")")
            }
            .font(Font(ThemeManager.shared.currentTheme.font(size: 14)))
            .foregroundColor(Color(ThemeManager.shared.currentTheme.accentText))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(ThemeManager.shared.currentTheme.accent).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("quickNavReconnectButton")
        .padding(.vertical, 24)
        .frame(height: 600)
    }

    private func reconnect() {
        guard let host = remoteHost else { return }
        let hostID = host.id
        Task { try? await RemoteConnectionRegistry.shared.reconnect(hostID: hostID) }
        onDismiss()
    }

    // MARK: - Actions

    private func loadInitialResults() {
        // Drop stale entries for hosts that no longer exist before showing anything
        FrecencyStore.shared.pruneUnknownRemoteHosts(knownHostIDs: knownHostIDs())

        if isRemoteScope {
            performRemoteSearch("")
            return
        }

        // Show top frecent directories on initial load
        frecencyResults = FrecencyStore.shared.frecencyLocationMatches(
            for: "", connectedHostIDs: connectedHostIDs(), limit: emptyQueryLimit
        )
        spotlightResults = []
        scopedResults = []
        updateMergedResults()
        selectedIndex = 0
    }

    private func performSearch(_ newQuery: String) {
        if isRemoteScope {
            performRemoteSearch(newQuery)
            return
        }

        // Cancel any in-flight Spotlight work
        spotlightDebounce?.cancel()
        spotlightSearch.cancel()
        scopedSearchTask?.cancel()

        let connected = connectedHostIDs()

        // Empty query: just show frecency
        if newQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            frecencyResults = FrecencyStore.shared.frecencyLocationMatches(
                for: "", connectedHostIDs: connected, limit: emptyQueryLimit
            )
            spotlightResults = []
            scopedResults = []
            updateMergedResults()
            return
        }

        // INSTANTLY show frecency matches (no blocking)
        frecencyResults = FrecencyStore.shared.frecencyLocationMatches(
            for: newQuery, connectedHostIDs: connected, limit: maxResults
        )
        updateMergedResults()

        let roots = searchRoots
        let includeHidden = SettingsManager.shared.searchIncludesHidden
        scopedSearchTask = Task { @MainActor in
            let urls = await Self.localMatches(
                for: newQuery,
                in: roots,
                includeHidden: includeHidden,
                limit: maxResults
            )
            guard !Task.isCancelled else { return }
            scopedResults = urls
            updateMergedResults()
        }

        // Debounce the filesystem-wide Spotlight search so fast typing doesn't
        // spin up an NSMetadataQuery on every keystroke.
        spotlightDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: spotlightDebounceInterval)
            guard !Task.isCancelled else { return }
            spotlightSearch.search(for: newQuery) { urls in
                spotlightResults = urls
                updateMergedResults()
            }
        }
    }

    /// IDs of remote hosts with a live connection right now.
    private func connectedHostIDs() -> Set<UUID> {
        Set(RemoteConnectionStateStore.shared.snapshot()
            .filter { $0.value == .connected }
            .map { $0.key })
    }

    /// IDs of all remote hosts that still exist in the host store.
    private func knownHostIDs() -> Set<UUID> {
        Set(RemoteHostStore.shared.hosts.map { $0.id })
    }

    /// Remote-scope search (A2-A6): show this host's recent locations immediately, then stream
    /// whole-host name matches from the server, debounced and cancelling the previous keystroke's
    /// search. Local Spotlight / scoped walk are never used here.
    private func performRemoteSearch(_ newQuery: String) {
        remoteSearchTask?.cancel()
        remoteSearchFailed = false

        guard !isDisconnectedRemote, let host = remoteHost, let provider = remoteProvider else {
            results = []
            remoteSearchInFlight = false
            return
        }

        // Recent remote places for THIS host only (A6), shown instantly alongside live results.
        frecencyResults = FrecencyStore.shared.frecencyLocationMatches(
            for: newQuery,
            remoteHosts: [host],
            connectedHostIDs: connectedHostIDs(),
            includeRemote: true,
            limit: maxResults
        ).filter {
            if case .remote(let hostID, _) = $0.location { return hostID == host.id }
            return false
        }
        remoteLiveResults = []

        let trimmed = newQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            remoteSearchInFlight = false
            updateRemoteMergedResults()
            return
        }

        // Spinner shows immediately (including during the debounce) so it is clear a search is running.
        remoteSearchInFlight = true
        updateRemoteMergedResults()

        let cap = remoteSearchCap
        remoteSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: spotlightDebounceInterval)
            guard !Task.isCancelled else { return }

            var collected: [QuickNavResult] = []
            do {
                for try await batch in provider.find(query: trimmed, cap: cap) {
                    guard !Task.isCancelled else { return }
                    collected.append(contentsOf: batch.map { item in
                        QuickNavResult.remote(
                            location: item.location,
                            host: host,
                            isConnected: true,
                            score: 0,
                            isDirectory: item.isDirectory
                        )
                    })
                    remoteLiveResults = collected
                    updateRemoteMergedResults()
                }
                // If a newer keystroke superseded this search, leave the in-flight state to it.
                guard !Task.isCancelled else { return }
                remoteSearchInFlight = false
                updateRemoteMergedResults()
            } catch is CancellationError {
                // Superseded by a newer keystroke; the new search owns the in-flight state.
            } catch {
                // The whole-host search failed (e.g. the helper rejected it); surface it instead of
                // silently showing "No matches", and never fall back to a local search.
                remoteSearchInFlight = false
                remoteSearchFailed = true
                updateRemoteMergedResults()
            }
        }
    }

    /// Merge this host's recent places (frecency, on top) with the live find results (server order:
    /// home and /opt first), de-duplicated by location. Server ordering is preserved, not re-sorted,
    /// so priority-root matches stay first (A3).
    private func updateRemoteMergedResults() {
        var seen = Set<Location>()
        var merged: [QuickNavResult] = []
        for result in frecencyResults + remoteLiveResults where !seen.contains(result.location) {
            seen.insert(result.location)
            merged.append(result)
        }
        results = Array(merged.prefix(maxResults))
        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
    }

    private func updateMergedResults() {
        results = FrecencyStore.shared.mergeLocationResults(
            frecency: frecencyResults,
            spotlight: scopedResults + spotlightResults,
            limit: maxResults
        )
        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
    }

    private static func localMatches(
        for query: String,
        in roots: [URL],
        includeHidden: Bool,
        limit: Int
    ) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let tokens = query
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0).lowercased() }
            guard !tokens.isEmpty, !roots.isEmpty else { return [] }

            let fileManager = FileManager.default
            let maxDepth = 4
            let maxVisitedPerRoot = 5_000
            var seen = Set<String>()
            var matches: [(url: URL, isDirectory: Bool, depth: Int)] = []

            for root in roots {
                guard matches.count < limit else { break }

                let rootURL = root.standardizedFileURL
                var isRootDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isRootDirectory),
                      isRootDirectory.boolValue else {
                    continue
                }

                var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                if !includeHidden {
                    options.insert(.skipsHiddenFiles)
                }

                guard let enumerator = fileManager.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: options
                ) else {
                    continue
                }

                let rootDepth = rootURL.pathComponents.count
                var visited = 0

                while let candidate = enumerator.nextObject() as? URL {
                    if Task.isCancelled || matches.count >= limit || visited >= maxVisitedPerRoot {
                        break
                    }
                    visited += 1

                    let url = candidate.standardizedFileURL
                    let depth = max(0, url.pathComponents.count - rootDepth)
                    if depth > maxDepth {
                        enumerator.skipDescendants()
                        continue
                    }

                    if url.path.contains(".app/") ||
                        url.path.contains(".xcodeproj/") ||
                        url.path.contains(".xcworkspace/") ||
                        url.path.contains("node_modules/") ||
                        url.path.contains(".git/") {
                        enumerator.skipDescendants()
                        continue
                    }

                    let name = url.lastPathComponent.lowercased()
                    guard tokens.allSatisfy({ name.localizedCaseInsensitiveContains($0) }) else {
                        continue
                    }

                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                    let isDirectory = values?.isDirectory == true
                    guard seen.insert(url.path).inserted else { continue }
                    matches.append((url, isDirectory, depth))
                }
            }

            matches.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                if lhs.depth != rhs.depth {
                    return lhs.depth < rhs.depth
                }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }

            return matches.prefix(limit).map(\.url)
        }.value
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let newIndex = selectedIndex + delta
        if newIndex >= 0 && newIndex < results.count {
            selectedIndex = newIndex
        }
    }

    private func selectCurrent() {
        guard !results.isEmpty && selectedIndex < results.count else { return }
        let result = results[selectedIndex]
        if let localURL = result.localURL {
            onSelect(localURL)
        } else {
            onSelectLocation?(result.location, result.isDirectory)
        }
    }

    private func revealCurrent() {
        guard !results.isEmpty && selectedIndex < results.count else { return }
        let result = results[selectedIndex]
        if let selected = result.localURL {
            // Navigate to containing folder and select the item
            onReveal(selected.deletingLastPathComponent(), selected)
        } else {
            onSelectLocation?(result.location, result.isDirectory)
        }
    }

    private func autocomplete() {
        guard !results.isEmpty && selectedIndex < results.count else { return }
        let selected = results[selectedIndex]
        query = selected.subtitle
    }
}

// MARK: - Result Row

private struct ResultRow: View {
    let result: QuickNavResult
    let isSelected: Bool
    let isFrecent: Bool
    let icon: NSImage

    private static let rowHeight: CGFloat = 48

    init(result: QuickNavResult, isSelected: Bool, isFrecent: Bool) {
        self.result = result
        self.isSelected = isSelected
        self.isFrecent = isFrecent

        let systemIcon: NSImage
        if result.isRemote {
            systemIcon = NSImage(systemSymbolName: "network", accessibilityDescription: nil) ?? NSImage()
        } else if let localURL = result.localURL {
            systemIcon = NSWorkspace.shared.icon(forFile: localURL.path)
        } else {
            systemIcon = NSImage()
        }
        systemIcon.size = NSSize(width: 20, height: 20)
        if result.isDirectory {
            self.icon = FileItem.tintedFolderIcon(systemIcon)
        } else {
            self.icon = systemIcon
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // File/folder icon
            Image(nsImage: icon)
                .frame(width: 20, height: 20)

            // Two-line display: filename + path
            VStack(alignment: .leading, spacing: 2) {
                // Line 1: Filename with star if frecent
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(Font(ThemeManager.shared.currentTheme.font(size: 13)))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isFrecent {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
                    }

                    if let hostLabel = result.hostLabel {
                        Text(hostLabel)
                            .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 10, weight: .medium)))
                            .foregroundColor(Color(ThemeManager.shared.currentTheme.accentText))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(ThemeManager.shared.currentTheme.accent).opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                // Line 2: Full path (secondary, smaller)
                Text(result.subtitle)
                    .font(Font(ThemeManager.shared.currentTheme.font(size: 11)))
                    .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Enter symbol for selected row
            if isSelected {
                Text("↵")
                    .font(Font(ThemeManager.shared.currentTheme.font(size: 12)))
                    .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Color(ThemeManager.shared.currentTheme.accent).opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityIdentifier("quickNavResultRow")
    }

    static var height: CGFloat { rowHeight }
}

#if canImport(PreviewsMacros)
    #Preview {
        QuickNavView(
            onSelect: { url in print("Selected: \(url)") },
            onReveal: { folder, item in print("Reveal: \(item) in \(folder)") },
            onDismiss: { print("Dismissed") }
        )
    }
#endif
