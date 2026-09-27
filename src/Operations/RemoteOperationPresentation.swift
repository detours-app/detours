import Foundation
import RemoteOperationSupport

struct RemoteOperationPresentation {
    struct Selection {
        let intent: OperationIntent
        let items: [RemoteOperationStore.Item]

        var skipped: Bool { intent.conflict == .skip }
        var unknown: Bool { items.contains { $0.outcome == .unknown || $0.result.receipt?.sourceDisposition == .unknown } }
        var completed: Bool {
            !skipped && !unknown && !items.isEmpty && items.allSatisfy { $0.outcome == .committed }
        }
        var changed: Bool { items.contains { !($0.result.receipt?.effects.isEmpty ?? true) } }
        var retainedSource: Bool {
            intent.action == .move && !completed && !unknown && items.contains {
                $0.result.intent.action == .copy && $0.outcome == .committed
            }
        }
    }

    let snapshot: RemoteOperationStore.Snapshot
    let active: Bool
    let hostNames: [UUID: String]
    var id: UUID { snapshot.record.operation }

    var selections: [Selection] {
        let selected = snapshot.selections ?? []
        let children = Set(selected.flatMap(\.children))
        return selected.map { intent in
            Selection(intent: intent, items: snapshot.items.filter { intent.children.contains($0.identity.id) })
        } + snapshot.items.filter { !children.contains($0.identity.id) }.map {
            Selection(intent: $0.result.intent, items: [$0])
        }
    }

    var needsCheck: Bool {
        snapshot.items.contains {
            [.unknown, .running, .stopping].contains($0.outcome) ||
                $0.result.receipt?.recovery.contains(where: { $0.knownLocation == nil }) == true
        }
    }

    var canCancel: Bool { active && !snapshot.record.cancellationRequested }
    var canUndo: Bool { !active && snapshot.items.contains { RemoteOperationCoordinator.canUndo($0, in: snapshot) } }

    var summary: String {
        if snapshot.record.cancellationRequested && active { return "Cancelling. Checking what finished..." }
        let selected = selections
        let completed = selected.filter(\.completed).count
        let unknown = selected.filter(\.unknown).count
        let skipped = selected.filter(\.skipped).count
        if active { return "\(completed) of \(selected.count) items completed." }
        if snapshot.record.cancellationRequested && !selected.contains(where: \.changed) && !needsCheck &&
            snapshot.items.allSatisfy({ [.notStarted, .failedUnchanged].contains($0.outcome) && ($0.result.receipt?.recovery.isEmpty ?? true) }) {
            return "Cancelled. No files changed."
        }
        var text = "\(completed) \(completed == 1 ? "item" : "items") completed"
        let remaining = selected.count - completed - skipped - unknown
        if remaining > 0 { text += "; \(remaining) couldn't be completed" }
        if unknown > 0 { text += "; \(unknown) \(unknown == 1 ? "result" : "results") unknown" }
        if skipped > 0 { text += "; \(skipped) skipped" }
        if selected.contains(where: \.retainedSource) { text += ". Copied files retain their originals" }
        if needsCheck && unknown == 0 { text += ". Some recovery locations remain unconfirmed" }
        return text + "."
    }

    func hostName(_ item: RemoteOperationStore.Item) -> String {
        hostNames[item.hostID] ?? item.result.account.hostIdentity
    }

    func status(_ item: RemoteOperationStore.Item) -> String {
        if item.result.intent.conflict == .skip { return "Skipped. No files changed." }
        switch item.outcome {
        case .notStarted: return "Not started."
        case .running: return "In progress."
        case .stopping: return "Cancelling. Checking what finished..."
        case .committed:
            if item.result.receipt?.sourceDisposition == .unknown { return "Destination completed; source result unknown." }
            if item.result.receipt?.sourceDisposition == .present { return "Copied. The original is still at its source." }
            return "Confirmed \(Self.completedAction(item.result.intent.action))."
        case .failedUnchanged: return "Not completed. No files changed."
        case .partial: return "Partly completed. Confirmed changes and retained files are listed below."
        case .unknown: return "Couldn't confirm whether this item was \(Self.completedAction(item.result.intent.action)) on \(hostName(item))."
        }
    }

    static func path(_ location: OperationLocation) -> String {
        switch location.path {
        case .windows(let path): return path
        case .unix(let bytes):
            return String(data: bytes, encoding: .utf8) ?? bytes.map { String(format: "\\x%02x", $0) }.joined()
        }
    }

    static func completedAction(_ action: OperationIntent.Action) -> String {
        switch action {
        case .copy: return "copied"
        case .move: return "moved"
        case .rename: return "renamed"
        case .trash: return "moved to Trash"
        case .restore: return "restored"
        case .createFolder: return "created"
        case .archiveCreate: return "archived"
        case .archiveExtract: return "extracted"
        case .editorUpload: return "saved"
        case .permanentDelete: return "deleted"
        case .undo: return "undone"
        }
    }
}
