import AppKit
import SwiftUI

@MainActor
final class RemoteOperationsWindowController: NSWindowController {
    static let shared = RemoteOperationsWindowController()

    private init() {
        let controller = NSHostingController(rootView: RemoteOperationsView())
        let window = NSWindow(contentViewController: controller)
        window.title = "Remote Operations"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier("closeRemoteOperations")
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct RemoteOperationsView: View {
    @State private var snapshots: [RemoteOperationStore.Snapshot] = []
    @State private var selected: RemoteResultModel?
    @State private var recoveryMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let recoveryMessage { Text(recoveryMessage).padding(.horizontal, 12) }
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshots, id: \.record.operation) { snapshot in
                            Button {
                                selected = RemoteResultModel(FileOperationQueue.shared.remotePresentation(snapshot))
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title(snapshot)).fontWeight(.semibold).lineLimit(2)
                                    Text(FileOperationQueue.shared.remotePresentation(snapshot).summary).lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(selected?.presentation.id == snapshot.record.operation
                                    ? Color.accentColor.opacity(0.15) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(title(snapshot))
                            .accessibilityIdentifier("remoteOperationRecord-" + snapshot.record.operation.uuidString)
                        }
                        if snapshots.isEmpty { Text("No saved remote operations.").padding(12) }
                    }
                }
                .frame(width: 260)
                Divider()
                if let selected {
                    RemoteOperationDetailView(model: selected)
                } else {
                    Text("Select an operation to inspect its recorded result.")
                        .frame(width: 480, height: 400)
                }
            }
        }
        .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 11)))
        .frame(width: 741, height: 450)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .remoteOperationResultsChanged)) { _ in refresh() }
    }

    private func refresh() {
        let queue = FileOperationQueue.shared
        snapshots = queue.remoteOperationResults.values.filter { !$0.items.isEmpty }.sorted {
            let left = queue.remotePresentation($0).needsCheck
            let right = queue.remotePresentation($1).needsCheck
            if left != right { return left }
            return $0.record.operation.uuidString < $1.record.operation.uuidString
        }
        recoveryMessage = queue.remoteRecoveryMessage
        if let selected, let current = queue.remoteOperationResults[selected.presentation.id] {
            selected.update(queue.remotePresentation(current))
        }
    }

    private func title(_ snapshot: RemoteOperationStore.Snapshot) -> String {
        let intent = snapshot.selections?.first ?? snapshot.items.first?.result.intent
        guard let location = intent?.sources.first ?? intent?.destination else { return "Remote operation" }
        switch location.path {
        case .unix:
            return URL(fileURLWithPath: RemoteOperationPresentation.path(location)).lastPathComponent
        case .windows(let path): return String(path.split(separator: "\\").last ?? Substring(path))
        }
    }
}
