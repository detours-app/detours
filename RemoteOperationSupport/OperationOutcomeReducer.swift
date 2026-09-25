import Foundation

public struct OperationOutcomeReducer: Codable, Equatable, Sendable {
    public let intent: OperationIntent
    public let account: OperationAccount
    public let epoch: UUID
    public let intentDigest: String
    public private(set) var receipt: OperationReceipt?
    public private(set) var submitted: Bool
    public private(set) var cancellationRequested: Bool
    public private(set) var contactLost: Bool
    public private(set) var undoRegistered: Bool

    public init(intent: OperationIntent, account: OperationAccount, epoch: UUID, intentDigest: String) {
        self.intent = intent
        self.account = account
        self.epoch = epoch
        self.intentDigest = intentDigest
        self.submitted = false
        self.cancellationRequested = false
        self.contactLost = false
        self.undoRegistered = false
    }

    public var outcome: OperationOutcome {
        if let receipt, [.committed, .failedUnchanged, .partial].contains(receipt.outcome) {
            return receipt.outcome
        }
        if submitted && contactLost { return .unknown }
        if submitted && cancellationRequested { return .stopping }
        return receipt?.outcome ?? (submitted ? .running : .notStarted)
    }

    public var maySubmit: Bool {
        !submitted && receipt == nil && !cancellationRequested && intent.conflict != .skip
    }

    public var shouldStopBatch: Bool {
        cancellationRequested || contactLost || outcome == .unknown || outcome == .partial
    }

    public mutating func markSubmitted() throws {
        guard maySubmit else { throw OperationContractError.invalidReceipt }
        submitted = true
    }

    public mutating func loseContact() {
        contactLost = true
    }

    public mutating func requestCancellation() {
        cancellationRequested = true
    }

    public mutating func receive(_ incoming: OperationReceipt) throws {
        guard incoming.schemaVersion == 1 else { throw OperationContractError.incompatibleSchema }
        guard incoming.id == intent.id, incoming.account == account else {
            throw OperationContractError.identityMismatch
        }
        guard incoming.epoch == epoch else { throw OperationContractError.epochMismatch }
        guard incoming.intentDigest == intentDigest else { throw OperationContractError.intentMismatch }
        if let receipt {
            if incoming.revision < receipt.revision { return }
            if incoming.revision == receipt.revision {
                guard incoming == receipt else { throw OperationContractError.conflictingRevision }
                return
            }
            if [.committed, .failedUnchanged].contains(receipt.outcome) {
                guard incoming.outcome == receipt.outcome, incoming.effects == receipt.effects else {
                    throw OperationContractError.invalidReceipt
                }
            }
        }
        try validate(incoming)
        receipt = incoming
        submitted = true
        contactLost = false
    }

    public mutating func takeUndoRegistration() -> OperationReceipt? {
        guard !undoRegistered, let receipt, !receipt.effects.isEmpty,
              [.committed, .partial].contains(receipt.outcome),
              receipt.sourceDisposition != .unknown,
              intent.action != .permanentDelete,
              receipt.recovery.allSatisfy({ $0.purpose == .scratch || $0.knownLocation != nil }) else {
            return nil
        }
        undoRegistered = true
        return receipt
    }

    private func validate(_ incoming: OperationReceipt) throws {
        if incoming.outcome == .notStarted { throw OperationContractError.invalidReceipt }
        if incoming.skipped && (intent.conflict != .skip || !incoming.effects.isEmpty) {
            throw OperationContractError.invalidReceipt
        }
        if incoming.outcome == .failedUnchanged && (!incoming.effects.isEmpty || !incoming.recovery.isEmpty) {
            throw OperationContractError.invalidReceipt
        }
        if incoming.outcome == .committed {
            guard incoming.children.allSatisfy({ $0.outcome == .committed || $0.skipped }) else {
                throw OperationContractError.invalidReceipt
            }
            if intent.action == .move && incoming.sourceDisposition != .confirmed {
                throw OperationContractError.invalidReceipt
            }
        }
    }
}
