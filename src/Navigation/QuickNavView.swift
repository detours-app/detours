import SwiftUI

/// SwiftUI view for the Cmd-P quick navigation popover.
struct QuickNavView: View {
    @State private var query: String = ""
    @State private var results: [URL] = []
    @State private var selectedIndex: Int = 0
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isTextFieldFocused: Bool

    let onSelect: (URL) -> Void
    let onDismiss: () -> Void

    private let maxResults = 10

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
                    debounceSearch(newValue)
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
                    .frame(maxHeight: CGFloat(min(results.count, maxResults)) * 36 + 8)
                    .onChange(of: selectedIndex) { _, newIndex in
                        withAnimation {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            // Footer with keyboard hints
            if !results.isEmpty {
                Divider()
                HStack(spacing: 16) {
                    Text("↑↓ navigate")
                    Text("↵ open")
                    Text("⇥ autocomplete")
                }
                .font(Font(NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)))
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadInitialResults()
            // Delay focus slightly to ensure window is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTextFieldFocused = true
            }
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
        results = FrecencyStore.shared.topDirectories(matching: "", limit: maxResults)
        selectedIndex = 0
    }

    private func debounceSearch(_ newQuery: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            guard !Task.isCancelled else { return }
            results = FrecencyStore.shared.topDirectories(matching: newQuery, limit: maxResults)
            selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
        }
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

    var body: some View {
        HStack(spacing: 8) {
            // Star icon for frecent items
            if isFrecent {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                Color.clear
                    .frame(width: 10)
            }

            // Path display
            Text(displayPath)
                .font(Font(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Enter symbol for selected row
            if isSelected {
                Text("↵")
                    .font(Font(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 36)
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
}

#Preview {
    QuickNavView(
        onSelect: { url in print("Selected: \(url)") },
        onDismiss: { print("Dismissed") }
    )
}
