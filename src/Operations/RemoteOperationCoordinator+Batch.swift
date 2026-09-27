import Foundation
import RemoteOperationSupport

extension RemoteOperationCoordinator {
    /// The entire ordered plan is durable before the first host accepts an item.
    func performBatch(_ plan: [PlannedItem], operation: UUID,
                      selections: [OperationIntent] = []) async throws -> RemoteOperationStore.Snapshot {
        guard activeBatches.insert(operation).inserted else { throw OperationJournalError.busy }
        defer { activeBatches.remove(operation) }
        let previous = try snapshot(operation)
        if previous.items.contains(where: { !$0.sent.isEmpty }) {
            guard previous.record.intents == plan.map(\.intent),
                  (previous.selections ?? []) == selections,
                  previous.items.map(\.hostID) == plan.map(\.hostID),
                  previous.items.map({ $0.requiresVerified ?? [] }) == plan.map(\.requiresVerified),
                  previous.items.map(\.preflightFailure) == plan.map(\.preflightFailure) else {
                throw OperationContractError.intentMismatch
            }
            return previous
        }
        try await persistPlan(plan, operation: operation)
        try recordSelections(selections, operation: operation)
        #if DEBUG
        if let gate = testHoldBeforeFirstItem {
            testHoldBeforeFirstItem = nil
            await gate()
        }
        #endif
        guard try snapshot(operation).record.intents.map(\.id) == plan.map({ $0.intent.id }) else {
            throw OperationContractError.intentMismatch
        }
        for planned in plan {
            let saved = try snapshot(operation)
            if saved.record.cancellationRequested || Task.isCancelled {
                try await cancel(operation)
                break
            }
            if planned.preflightFailure == .disconnected { break }
            if planned.preflightFailure != nil { continue }
            guard planned.requiresVerified.allSatisfy({ dependency in
                guard let item = saved.items.first(where: { $0.identity.id == dependency }),
                      item.outcome == .committed, let receipt = item.result.receipt else { return false }
                return receipt.contentVerified && !receipt.effects.isEmpty && !item.result.contactLost
            }) else { continue }
            let result = try await perform(planned.intent, hostID: planned.hostID, work: planned.work)
            if result.outcome == .unknown {
                // A request error may have a conclusive failed-unchanged host receipt. Only that
                // evidence permits the next item; an ambiguous or newly discovered commit stops.
                do {
                    let checked = try await checkResult(planned.intent.id)
                    if checked.outcome == .failedUnchanged && !checked.cancellationRequested { continue }
                } catch {
                    return try snapshot(operation)
                }
                break
            }
            if result.shouldStopBatch { break }
        }
        return try snapshot(operation)
    }

    private func persistPlan(_ plan: [PlannedItem], operation: UUID) async throws {
        var preceding: Set<OperationItemID> = []
        for planned in plan {
            guard planned.requiresVerified.allSatisfy({ preceding.contains($0) }),
                  preceding.insert(planned.intent.id).inserted else { throw OperationContractError.invalidReceipt }
        }
        for planned in plan {
            guard planned.intent.id.operation == operation else { throw OperationContractError.identityMismatch }
            try await recordPlannedItem(planned)
        }
    }
}
