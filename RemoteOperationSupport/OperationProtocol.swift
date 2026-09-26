import Foundation

public enum OperationCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case receipts
    case status
    case cancellation
    case ownedTemporaryObjects
    case nonReplacingCommit
    case sourceProof
}

public enum OperationCompatibilityError: Error, Codable, Equatable, Sendable {
    case protocolVersion(expected: Int, actual: Int)
    case journalSchema(expected: Int, actual: Int)
    case missingCapabilities(Set<OperationCapability>)
    case accountMismatch
    case epochChanged
}

public struct OperationHandshake: Codable, Equatable, Sendable {
    public static let protocolVersion = 2
    public static let journalSchema = 1

    public let version: Int
    public let schemaVersion: Int
    public let capabilities: Set<OperationCapability>
    public let account: OperationAccount
    public let epoch: UUID

    public init(version: Int, schemaVersion: Int, capabilities: Set<OperationCapability>, account: OperationAccount, epoch: UUID) {
        self.version = version
        self.schemaVersion = schemaVersion
        self.capabilities = capabilities
        self.account = account
        self.epoch = epoch
    }

    public func validate(expectedAccount: OperationAccount?, expectedEpoch: UUID?) throws {
        guard version == Self.protocolVersion else {
            throw OperationCompatibilityError.protocolVersion(expected: Self.protocolVersion, actual: version)
        }
        guard schemaVersion == Self.journalSchema else {
            throw OperationCompatibilityError.journalSchema(expected: Self.journalSchema, actual: schemaVersion)
        }
        let missing = Set(OperationCapability.allCases).subtracting(capabilities)
        guard missing.isEmpty else { throw OperationCompatibilityError.missingCapabilities(missing) }
        if let expectedAccount, account != expectedAccount { throw OperationCompatibilityError.accountMismatch }
        if let expectedEpoch, epoch != expectedEpoch { throw OperationCompatibilityError.epochChanged }
    }
}

public struct OperationRequestIdentity: Codable, Equatable, Sendable {
    public let id: OperationItemID
    public let account: OperationAccount
    public let epoch: UUID
    public let intentDigest: String

    public init(id: OperationItemID, account: OperationAccount, epoch: UUID, intentDigest: String) {
        self.id = id
        self.account = account
        self.epoch = epoch
        self.intentDigest = intentDigest
    }
}

public enum OperationRequest: Codable, Equatable, Sendable {
    case handshake(version: Int, schemaVersion: Int, requiredCapabilities: Set<OperationCapability>)
    case lookup(OperationLocation)
    case sourceProof(OperationLocation)
    case accept(identity: OperationRequestIdentity, intent: OperationIntent)
    case prepareUpload(identity: OperationRequestIdentity, contents: Data)
    case prepareCopy(OperationRequestIdentity)
    case prepareArchive(identity: OperationRequestIdentity, password: String?)
    case commit(OperationRequestIdentity)
    case execute(OperationRequestIdentity)
    case status(OperationRequestIdentity)
    case cancel(OperationRequestIdentity)
    case acknowledge(identity: OperationRequestIdentity, retainingUndo: Bool)

    public static var handshake: Self {
        .handshake(version: OperationHandshake.protocolVersion, schemaVersion: OperationHandshake.journalSchema,
                   requiredCapabilities: Set(OperationCapability.allCases))
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

public enum OperationReply: Codable, Equatable, Sendable {
    case handshake(OperationHandshake)
    case lookup(OperationLookup<OperationObservation>)
    case accepted(OperationJournal.Snapshot)
    case status(OperationJournal.Snapshot)
    case cancellationRecorded(OperationRequestIdentity)
    case acknowledged(OperationRequestIdentity)
    case receipt(OperationReceipt)
    case incompatible(OperationCompatibilityError)

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

public struct OperationStreamHandshake: Codable, Equatable, Sendable {
    public let version: Int
    public let identity: OperationRequestIdentity

    public init(identity: OperationRequestIdentity) {
        self.version = OperationHandshake.protocolVersion
        self.identity = identity
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) throws -> Self {
        let handshake = try JSONDecoder().decode(Self.self, from: data)
        guard handshake.version == OperationHandshake.protocolVersion else {
            throw OperationCompatibilityError.protocolVersion(expected: OperationHandshake.protocolVersion, actual: handshake.version)
        }
        return handshake
    }
}
