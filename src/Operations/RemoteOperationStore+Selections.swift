import RemoteOperationSupport

extension RemoteOperationStore.Snapshot {
    func outcome(for selection: OperationIntent) -> OperationOutcome {
        let children = selection.children.compactMap { id in items.first { $0.identity.id == id } }
        guard children.count == selection.children.count else { return .unknown }
        if children.contains(where: { $0.outcome == .unknown }) { return .unknown }
        if children.contains(where: { $0.outcome == .stopping }) { return .stopping }
        if children.contains(where: { $0.outcome == .running }) { return .running }
        if children.allSatisfy({ $0.outcome == .committed || $0.result.intent.conflict == .skip }) { return .committed }
        if children.contains(where: { $0.outcome == .committed || $0.outcome == .partial }) { return .partial }
        if children.contains(where: { $0.outcome == .failedUnchanged }) { return .failedUnchanged }
        return .notStarted
    }
}
