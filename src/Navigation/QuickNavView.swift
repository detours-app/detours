import SwiftUI

/// SwiftUI view for the Cmd-P quick navigation popover.
struct QuickNavView: View {
    @State private var query: String = ""
    @State private var results: [QuickNavResult] = []
    @State private var frecencyResults: [QuickNavResult] = []
    @State private var scopedFilesystemResults: [QuickNavResult] = []
    @State private var spotlightResults: [URL] = []
    @State private var selectedIndex: Int = 0
    @State private var spotlightSearch = SpotlightSearch()
    @State private var spotlightDebounce: Task<Void, Never>?
    @FocusState private var isTextFieldFocused: Bool

    var searchRoot: URL?
    var onActiveResultChange: ((QuickNavResult?) -> Void)?
    let onSelect: (URL) -> Void
    var onSelectLocation: ((Location) -> Void)?
    let onReveal: (_ folder: URL, _ itemToSelect: URL) -> Void
    let onDismiss: () -> Void

    private let maxResults = 50
    private let emptyQueryLimit = 12
    private let spotlightDebounceInterval: UInt64 = 150_000_000

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
                .onChange(of: query) { _, newValue in
                    performSearch(newValue)
                }

            Divider()

            // Results list
            if results.isEmpty && !query.isEmpty {
                Text("No matches")
                    .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
                    .padding(.vertical, 24)
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
    }

    // MARK: - Actions

    private func loadInitialResults() {
        // Drop stale entries for hosts that no longer exist before showing anything
        FrecencyStore.shared.pruneUnknownRemoteHosts(knownHostIDs: knownHostIDs())

        // Show top frecent directories on initial load
        frecencyResults = FrecencyStore.shared.frecencyLocationMatches(
            for: "", connectedHostIDs: connectedHostIDs(), limit: emptyQueryLimit
        )
        spotlightResults = []
        updateMergedResults()
        selectedIndex = 0
    }

    private func performSearch(_ newQuery: String) {
        // Cancel any in-flight Spotlight work
        spotlightDebounce?.cancel()
        spotlightSearch.cancel()

        let connected = connectedHostIDs()

        // Empty query: just show frecency
        if newQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            frecencyResults = FrecencyStore.shared.frecencyLocationMatches(
                for: "", connectedHostIDs: connected, limit: emptyQueryLimit
            )
            scopedFilesystemResults = []
            spotlightResults = []
            updateMergedResults()
            return
        }

        // INSTANTLY show frecency matches (no blocking)
        frecencyResults = FrecencyStore.shared.frecencyLocationMatches(
            for: newQuery, connectedHostIDs: connected, limit: maxResults
        )
        scopedFilesystemResults = scopedFilesystemMatches(for: newQuery)
        updateMergedResults()

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

    private func updateMergedResults() {
        results = FrecencyStore.shared.mergeLocationResults(
            frecency: scopedFilesystemResults + frecencyResults,
            spotlight: spotlightResults,
            limit: maxResults
        )
        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
        publishActiveResult()
    }

    private func scopedFilesystemMatches(for query: String) -> [QuickNavResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let searchRoot else { return [] }

        let root = searchRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let queryLower = trimmedQuery.lowercased()
        let rootDepth = root.pathComponents.count
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var matches: [QuickNavResult] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            if values?.isPackage == true {
                enumerator.skipDescendants()
            }
            if values?.isHidden == true && !SettingsManager.shared.searchIncludesHidden {
                continue
            }

            let name = url.lastPathComponent
            guard name.localizedCaseInsensitiveContains(trimmedQuery) else { continue }

            let score = scopedFilesystemScore(name: name, queryLower: queryLower, depth: url.pathComponents.count - rootDepth)
            matches.append(.local(url: url, score: score, isDirectory: values?.isDirectory == true))
            if matches.count >= maxResults * 2 {
                break
            }
        }

        return matches.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func scopedFilesystemScore(name: String, queryLower: String, depth: Int) -> Double {
        let nameLower = name.lowercased()
        let base: Double
        if nameLower == queryLower {
            base = 1_000
        } else if nameLower.hasPrefix(queryLower) {
            base = 750
        } else {
            base = 500
        }
        return base - Double(max(depth, 0))
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let newIndex = selectedIndex + delta
        if newIndex >= 0 && newIndex < results.count {
            selectedIndex = newIndex
            publishActiveResult()
        }
    }

    private func publishActiveResult() {
        guard !results.isEmpty && selectedIndex < results.count else {
            onActiveResultChange?(nil)
            return
        }
        onActiveResultChange?(results[selectedIndex])
    }

    private func selectCurrent() {
        guard !results.isEmpty && selectedIndex < results.count else { return }
        let result = results[selectedIndex]
        if let localURL = result.localURL {
            onSelect(localURL)
        } else {
            onSelectLocation?(result.location)
        }
    }

    private func revealCurrent() {
        guard !results.isEmpty && selectedIndex < results.count else { return }
        guard let selected = results[selectedIndex].localURL else { return }
        // Navigate to containing folder and select the item
        onReveal(selected.deletingLastPathComponent(), selected)
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
