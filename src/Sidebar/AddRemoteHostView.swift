import SwiftUI

enum AddRemoteHostTestResult: Equatable {
    case trusted
}

enum AddRemoteHostPickerRow: Equatable, Identifiable {
    case typedTarget(String)
    case suggestion(String)
    case guidance

    var id: String {
        switch self {
        case .typedTarget(let target):
            "typed:\(target)"
        case .suggestion(let suggestion):
            "suggestion:\(suggestion)"
        case .guidance:
            "guidance"
        }
    }

    var title: String {
        switch self {
        case .typedTarget(let target):
            "Add \(target)"
        case .suggestion(let suggestion):
            suggestion
        case .guidance:
            "Type an SSH host"
        }
    }
}

@Observable
@MainActor
final class AddRemoteHostModel {
    var sshTarget: String = "" {
        didSet {
            guard sshTarget != oldValue else { return }
            selectedSuggestionIndex = nil
            refreshSuggestionState()
        }
    }
    var suggestions: [String] {
        didSet {
            refreshSuggestionState()
        }
    }
    var selectedSuggestionIndex: Int?
    var errorMessage: String?
    var isTestingConnection = false
    private(set) var filteredSuggestions: [String] = []
    private(set) var visibleSuggestions: [String] = []
    private(set) var showsTypedTargetRow = false
    private(set) var visibleRows: [AddRemoteHostPickerRow] = []

    private var rankedFilteredSuggestions: [String] {
        let query = suggestionQuery
        guard !query.isEmpty else { return suggestions }
        return suggestions
            .enumerated()
            .filter { $0.element.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                let lhsRank = matchRank(lhs.element, query: query)
                let rhsRank = matchRank(rhs.element, query: query)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                if lhsRank <= 1, lhs.element.count != rhs.element.count {
                    return lhs.element.count < rhs.element.count
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var selectedSuggestion: String? {
        guard let highlightedSuggestionIndex else {
            return nil
        }
        return visibleSuggestions[highlightedSuggestionIndex]
    }

    var highlightedSuggestionIndex: Int? {
        guard !visibleSuggestions.isEmpty else { return nil }
        if let selectedSuggestionIndex,
           visibleSuggestions.indices.contains(selectedSuggestionIndex) {
            return selectedSuggestionIndex
        }
        if showsTypedTargetRow {
            return nil
        }
        return 0
    }

    var highlightedRowIndex: Int? {
        let count = visibleSuggestions.count + (showsTypedTargetRow ? 1 : 0)
        guard count > 0 else { return nil }
        if let selectedSuggestionIndex,
           visibleSuggestions.indices.contains(selectedSuggestionIndex) {
            return selectedSuggestionIndex + (showsTypedTargetRow ? 1 : 0)
        }
        return 0
    }

    var effectiveSSHTarget: String {
        sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canAdd: Bool {
        !effectiveSSHTarget.isEmpty
    }

    private var suggestionQuery: String {
        effectiveSSHTarget
    }

    private var exactSuggestion: String? {
        guard !effectiveSSHTarget.isEmpty else { return nil }
        return suggestions.first {
            $0.caseInsensitiveCompare(effectiveSSHTarget) == .orderedSame
        }
    }

    init(suggestions: [String] = AddRemoteHostModel.defaultSuggestions()) {
        self.suggestions = suggestions
        refreshSuggestionState()
    }

    func selectSuggestion(_ suggestion: String) {
        sshTarget = suggestion
        selectedSuggestionIndex = nil
    }

    func moveSuggestionSelection(by delta: Int) {
        let typedRowOffset = showsTypedTargetRow ? 1 : 0
        let rowCount = visibleSuggestions.count + typedRowOffset
        guard rowCount > 0 else {
            selectedSuggestionIndex = nil
            return
        }

        let current = highlightedRowIndex ?? 0
        let next = min(max(current + delta, 0), rowCount - 1)
        if showsTypedTargetRow && next == 0 {
            selectedSuggestionIndex = nil
        } else {
            selectedSuggestionIndex = next - typedRowOffset
        }
    }

    func resetSuggestionSelection() {
        selectedSuggestionIndex = nil
        refreshSuggestionState()
    }

    func commitTarget() -> String {
        if let selectedSuggestion {
            return selectedSuggestion
        }
        if let exactSuggestion {
            return exactSuggestion
        }
        return effectiveSSHTarget
    }

    func applyCommitTarget() {
        sshTarget = commitTarget()
        selectedSuggestionIndex = nil
        refreshSuggestionState()
    }

    func makeHost() -> RemoteHost {
        RemoteHost(
            displayName: effectiveSSHTarget,
            sshTarget: effectiveSSHTarget
        )
    }

    private static func defaultSuggestions() -> [String] {
        let storedHosts = RemoteHostStore.shared.hosts.map(\.sshTarget)
        let configHosts = SSHConfigParser().hostSuggestions(
            fromConfigAt: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        )

        var suggestions: [String] = []
        var seen: Set<String> = []
        for suggestion in storedHosts + configHosts {
            let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                suggestions.append(trimmed)
            }
        }
        return suggestions
    }

    private func matchRank(_ suggestion: String, query: String) -> Int {
        if suggestion.caseInsensitiveCompare(query) == .orderedSame {
            return 0
        }
        if suggestion.range(of: query, options: [.caseInsensitive, .anchored]) != nil {
            return 1
        }
        return 2
    }

    private func refreshSuggestionState() {
        filteredSuggestions = rankedFilteredSuggestions
        showsTypedTargetRow = !effectiveSSHTarget.isEmpty && exactSuggestion == nil
        visibleSuggestions = Array(filteredSuggestions.prefix(showsTypedTargetRow ? 7 : 8))
        visibleRows = makeVisibleRows()
        if let selectedSuggestionIndex,
           !visibleSuggestions.indices.contains(selectedSuggestionIndex) {
            self.selectedSuggestionIndex = nil
        }
    }

    private func makeVisibleRows() -> [AddRemoteHostPickerRow] {
        if showsTypedTargetRow {
            return [.typedTarget(effectiveSSHTarget)] + visibleSuggestions.map(AddRemoteHostPickerRow.suggestion)
        }
        if visibleSuggestions.isEmpty {
            return [.guidance]
        }
        return visibleSuggestions.map(AddRemoteHostPickerRow.suggestion)
    }
}

struct AddRemoteHostView: View {
    @Bindable var model: AddRemoteHostModel
    var onTestConnection: (String) async throws -> AddRemoteHostTestResult
    var onAdd: (RemoteHost) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            resultsList

            if let errorMessage = model.errorMessage {
                errorView(errorMessage)
            }

            Divider()
            footer
        }
        .frame(width: 540, height: 360)
        .background(Color(ThemeManager.shared.currentTheme.background))
        .onKeyPress(.upArrow) {
            model.moveSuggestionSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSuggestionSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
        .onKeyPress(.return) {
            Task { await addSelectedOrTypedHost() }
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 16))
                .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))

            SSHSuggestionTextField(
                text: $model.sshTarget,
                placeholder: "Add remote host...",
                isEnabled: !model.isTestingConnection,
                onTextChanged: {
                    model.resetSuggestionSelection()
                },
                onMoveSelection: { delta in
                    model.moveSuggestionSelection(by: delta)
                },
                onCancel: {
                    onCancel()
                },
                onCommit: {
                    Task { await addSelectedOrTypedHost() }
                }
            )
            .frame(height: 24)

            if model.isTestingConnection {
                ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.visibleRows.enumerated()), id: \.element.id) { index, row in
                        pickerRow(row, isSelected: index == model.highlightedRowIndex)
                            .id(row.id)
                            .onTapGesture {
                                activateRow(row)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.highlightedRowIndex) { _, index in
                guard let index else { return }
                withAnimation {
                    guard model.visibleRows.indices.contains(index) else {
                        return
                    }
                    proxy.scrollTo(model.visibleRows[index].id, anchor: .center)
                }
            }
        }
    }

    private func pickerRow(_ row: AddRemoteHostPickerRow, isSelected: Bool) -> some View {
        switch row {
        case .typedTarget(let target):
            return AnyView(typedTargetRow(target, isSelected: isSelected))
        case .suggestion(let suggestion):
            return AnyView(suggestionRow(suggestion, isSelected: isSelected))
        case .guidance:
            return AnyView(guidanceRow)
        }
    }

    private func typedTargetRow(_ target: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 18))
                .frame(width: 22, height: 22)
                .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))

            VStack(alignment: .leading, spacing: 2) {
                Text("Add \(target)")
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 13, weight: .medium)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Connects over SSH before adding it")
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 11)))
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                Text("↵")
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 12)))
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(isSelected ? Color(ThemeManager.shared.currentTheme.accent).opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add \(target)")
    }

    private var guidanceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 18))
                .frame(width: 22, height: 22)
                .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))

            VStack(alignment: .leading, spacing: 2) {
                Text("Type an SSH host")
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 13, weight: .medium)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("~/.ssh/config aliases and recent hosts appear here")
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 11)))
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Type an SSH host")
    }

    private func suggestionRow(_ suggestion: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 18))
                .frame(width: 22, height: 22)
                .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion)
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 13, weight: .medium)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(suggestionSourceDescription(for: suggestion))
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 11)))
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isSelected {
                Text("↵")
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 12)))
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(isSelected ? Color(ThemeManager.shared.currentTheme.accent).opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(suggestion)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if model.isTestingConnection {
                Text("Connecting...")
            } else {
                Text("↑↓ navigate")
                Text("↵ connect")
                Text("esc close")
            }
            Spacer()
        }
        .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 12)))
        .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 12)))
                .foregroundStyle(.red)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    @MainActor
    private func addSelectedOrTypedHost() async {
        model.applyCommitTarget()
        await addHost()
    }

    @MainActor
    private func addHost() async {
        guard !model.effectiveSSHTarget.isEmpty else { return }
        guard !model.isTestingConnection else { return }
        model.isTestingConnection = true
        model.errorMessage = nil
        defer { model.isTestingConnection = false }

        do {
            switch try await onTestConnection(model.effectiveSSHTarget) {
            case .trusted:
                onAdd(model.makeHost())
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func suggestionSourceDescription(for suggestion: String) -> String {
        RemoteHostStore.shared.hosts.contains { $0.sshTarget.caseInsensitiveCompare(suggestion) == .orderedSame }
            ? "Recent remote host"
            : "~/.ssh/config"
    }

    private func activateRow(_ row: AddRemoteHostPickerRow) {
        switch row {
        case .typedTarget:
            Task { await addHost() }
        case .suggestion(let suggestion):
            model.selectSuggestion(suggestion)
            Task { await addHost() }
        case .guidance:
            break
        }
    }
}

private struct SSHSuggestionTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onTextChanged: () -> Void
    let onMoveSelection: (Int) -> Void
    let onCancel: () -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> KeyHandlingTextField {
        let textField = KeyHandlingTextField()
        textField.placeholderString = placeholder
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = ThemeManager.shared.currentTheme.uiFont(size: 16)
        textField.delegate = context.coordinator
        textField.onMoveSelection = onMoveSelection
        textField.onCancel = onCancel
        textField.onCommit = onCommit

        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }

        return textField
    }

    func updateNSView(_ nsView: KeyHandlingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled
        nsView.font = ThemeManager.shared.currentTheme.uiFont(size: 16)
        nsView.onMoveSelection = onMoveSelection
        nsView.onCancel = onCancel
        nsView.onCommit = onCommit
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SSHSuggestionTextField

        init(_ parent: SSHSuggestionTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
            parent.onTextChanged()
        }
    }
}

private final class KeyHandlingTextField: NSTextField {
    var onMoveSelection: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            onMoveSelection?(1)
        case 126:
            onMoveSelection?(-1)
        case 53:
            onCancel?()
        case 36, 76:
            onCommit?()
        default:
            super.keyDown(with: event)
        }
    }
}
