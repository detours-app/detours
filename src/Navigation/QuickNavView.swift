import SwiftUI

/// SwiftUI view for the Cmd-P quick navigation popover.
struct QuickNavView: View {
    @State private var query: String = ""
    @State private var results: [URL] = []
    @State private var frecencyResults: [URL] = []
    @State private var spotlightResults: [URL] = []
    @State private var selectedIndex: Int = 0
    @State private var spotlightSearch = SpotlightSearch()
    @FocusState private var isTextFieldFocused: Bool

    let onSelect: (URL) -> Void
    let onReveal: (URL) -> Void
    let onDismiss: () -> Void

    private let maxResults = 20

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            TextField("Quick Open...", text: $query)
                .textFieldStyle(.plain)
                .font(Font(NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .focused($isTextFieldFocused)
                .onSubmit {
                    selectCurrent()
                }
                .onChange(of: query) { _, newValue in
                    performSearch(newValue)
                }

            Divider()

            // Results list
            if results.isEmpty && !query.isEmpty {
                Text("No matches")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.offset) { index, url in
                                ResultRow(
                                    url: url,
                                    isSelected: index == selectedIndex,
                                    isFrecent: FrecencyStore.shared.isFrecent(url)
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
                    .frame(height: CGFloat(maxResults) * ResultRow.height + 8)
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
            .font(Font(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))
            .foregroundColor(.secondary)
            .padding(.vertical, 8)
        }
        .frame(width: 900)
        .background(Color(nsColor: .windowBackgroundColor))
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
    }

    // MARK: - Actions

    private func loadInitialResults() {
        // Show top frecent directories on initial load
        frecencyResults = FrecencyStore.shared.frecencyMatches(for: "", limit: maxResults)
        spotlightResults = []
        updateMergedResults()
        selectedIndex = 0
    }

    private func performSearch(_ newQuery: String) {
        // Cancel any existing Spotlight search
        spotlightSearch.cancel()

        // Empty query: just show frecency
        if newQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            frecencyResults = FrecencyStore.shared.frecencyMatches(for: "", limit: maxResults)
            spotlightResults = []
            updateMergedResults()
            return
        }

        // INSTANTLY show frecency matches (no blocking)
        frecencyResults = FrecencyStore.shared.frecencyMatches(for: newQuery, limit: maxResults)
        updateMergedResults()

        // Start async Spotlight search - results stream in via callback
        spotlightSearch.search(for: newQuery) { [self] urls in
            spotlightResults = urls
            updateMergedResults()
        }
    }

    private func updateMergedResults() {
        results = FrecencyStore.shared.mergeResults(
            frecency: frecencyResults,
            spotlight: spotlightResults,
            limit: maxResults
        )
        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
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
        onSelect(results[selectedIndex])
    }

    private func revealCurrent() {
        guard !results.isEmpty && selectedIndex < results.count else { return }
        let selected = results[selectedIndex]
        // For files, reveal = go to enclosing folder. For folders, same as select.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDir), !isDir.boolValue {
            onReveal(selected.deletingLastPathComponent())
        } else {
            onReveal(selected)
        }
    }

    private func autocomplete() {
        guard !results.isEmpty && selectedIndex < results.count else { return }
        let selected = results[selectedIndex]
        query = displayPath(for: selected)
    }

    private func displayPath(for url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Result Row

private struct ResultRow: View {
    let url: URL
    let isSelected: Bool
    let isFrecent: Bool
    let isDirectory: Bool
    let icon: NSImage

    private static let rowHeight: CGFloat = 48

    init(url: URL, isSelected: Bool, isFrecent: Bool) {
        self.url = url
        self.isSelected = isSelected
        self.isFrecent = isFrecent

        // Check if directory and get appropriate icon
        var isDir: ObjCBool = false
        self.isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue

        let systemIcon = NSWorkspace.shared.icon(forFile: url.path)
        systemIcon.size = NSSize(width: 20, height: 20)
        if self.isDirectory {
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
                    Text(url.lastPathComponent)
                        .font(Font(NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isFrecent {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

                // Line 2: Full path (secondary, smaller)
                Text(displayPath)
                    .font(Font(NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Enter symbol for selected row
            if isSelected {
                Text("↵")
                    .font(Font(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }

    private var displayPath: String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static var height: CGFloat { rowHeight }
}

#Preview {
    QuickNavView(
        onSelect: { url in print("Selected: \(url)") },
        onReveal: { url in print("Reveal: \(url)") },
        onDismiss: { print("Dismissed") }
    )
}
