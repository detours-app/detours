import Foundation

public enum OperationPhase: String, Codable, Sendable {
    case accepted, preparing, readyToCommit, committing, committed, rollingBack, terminal
}

public enum OperationOutcome: String, Codable, Sendable {
    case notStarted, running, stopping, committed, failedUnchanged, partial, unknown
}

public struct OperationRecoveryReference: Codable, Equatable, Sendable {
    public enum Purpose: String, Codable, Sendable {
        case scratch, displacedOriginal, sourceTrash
    }

    public let identity: OperationObjectIdentity
    public let purpose: Purpose
    public let original: OperationLocation?
    public let knownLocation: OperationLocation?
    public let possibleLocations: [OperationLocation]

    public init(
        identity: OperationObjectIdentity, purpose: Purpose, original: OperationLocation?,
        knownLocation: OperationLocation?, possibleLocations: [OperationLocation]
    ) {
        self.identity = identity
        self.purpose = purpose
        self.original = original
        self.knownLocation = knownLocation
        self.possibleLocations = possibleLocations
    }
}

public struct OperationEffect: Codable, Equatable, Sendable {
    public let location: OperationLocation
    public let observation: OperationObservation

    public init(location: OperationLocation, observation: OperationObservation) {
        self.location = location
        self.observation = observation
    }
}

public struct OperationReceipt: Codable, Equatable, Sendable {
    public enum SourceDisposition: String, Codable, Sendable {
        case notRequired, present, confirmed, unknown
    }

    public let schemaVersion: Int
    public let id: OperationItemID
    public let account: OperationAccount
    public let epoch: UUID
    public let intentDigest: String
    public let revision: UInt64
    public let phase: OperationPhase
    public let outcome: OperationOutcome
    public let effects: [OperationEffect]
    public let sourceDisposition: SourceDisposition
    public let contentVerified: Bool
    public let preparedPayload: OperationEffect?
    public let recovery: [OperationRecoveryReference]
    public let children: [OperationReceipt]
    public let skipped: Bool
    public let failure: String?

    public init(
        id: OperationItemID, account: OperationAccount, epoch: UUID,
        intentDigest: String, revision: UInt64, phase: OperationPhase,
        outcome: OperationOutcome, effects: [OperationEffect] = [],
        sourceDisposition: SourceDisposition = .notRequired, contentVerified: Bool = false,
        preparedPayload: OperationEffect? = nil,
        recovery: [OperationRecoveryReference] = [], children: [OperationReceipt] = [],
        skipped: Bool = false, failure: String? = nil
    ) {
        self.schemaVersion = 1
        self.id = id
        self.account = account
        self.epoch = epoch
        self.intentDigest = intentDigest
        self.revision = revision
        self.phase = phase
        self.outcome = outcome
        self.effects = effects
        self.sourceDisposition = sourceDisposition
        self.contentVerified = contentVerified
        self.preparedPayload = preparedPayload
        self.recovery = recovery
        self.children = children
        self.skipped = skipped
        self.failure = failure
    }
}

public struct OperationRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operation: UUID
    public private(set) var intents: [OperationIntent]
    public private(set) var cancellationRequested: Bool

    public init(operation: UUID) {
        self.schemaVersion = 1
        self.operation = operation
        self.intents = []
        self.cancellationRequested = false
    }

    public mutating func accept(_ intent: OperationIntent) throws {
        guard intent.id.operation == operation else { throw OperationContractError.identityMismatch }
        if let accepted = intents.first(where: { $0.id == intent.id }) {
            guard accepted == intent else { throw OperationContractError.intentMismatch }
            return
        }
        guard !cancellationRequested else { throw OperationContractError.cancelled }
        intents.append(intent)
    }

    public mutating func requestCancellation() {
        cancellationRequested = true
    }
}

public enum OperationContractError: Error, Equatable {
    case identityMismatch, intentMismatch, incompatibleSchema, epochMismatch
    case conflictingRevision, invalidReceipt, cancelled
}
