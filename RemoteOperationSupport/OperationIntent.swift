import Foundation

public struct OperationItemID: Codable, Hashable, Sendable {
    public let operation: UUID
    public let item: UUID

    public init(operation: UUID, item: UUID) {
        self.operation = operation
        self.item = item
    }
}

public struct OperationAccount: Codable, Hashable, Sendable {
    public let hostIdentity: String
    public let accountIdentity: String

    public init(hostIdentity: String, accountIdentity: String) {
        self.hostIdentity = hostIdentity
        self.accountIdentity = accountIdentity
    }
}

public struct OperationLocation: Codable, Hashable, Sendable {
    public enum Path: Codable, Hashable, Sendable {
        case unix(Data)
        case windows(String)
    }

    public let account: OperationAccount
    public let path: Path

    public init(account: OperationAccount, path: Path) {
        self.account = account
        self.path = path
    }
}

public struct OperationObjectIdentity: Codable, Hashable, Sendable {
    public let volume: Data
    public let object: Data

    public init(volume: Data, object: Data) {
        self.volume = volume
        self.object = object
    }
}

public struct OperationObservation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file, directory, symbolicLink
    }

    public let identity: OperationObjectIdentity
    public let kind: Kind
    public let version: Data
    public let byteCount: UInt64
    public let sha256: String?
    public let linkTarget: Data?

    public init(
        identity: OperationObjectIdentity, kind: Kind, version: Data,
        byteCount: UInt64, sha256: String?, linkTarget: Data?
    ) {
        self.identity = identity
        self.kind = kind
        self.version = version
        self.byteCount = byteCount
        self.sha256 = sha256
        self.linkTarget = linkTarget
    }
}

public enum OperationLookup<Value: Sendable>: Sendable {
    case found(Value)
    case missing
    case denied
    case disconnected
    case unsupported
}

extension OperationLookup: Equatable where Value: Equatable {}

public struct OperationIntent: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case copy, move, rename, trash, restore, createFolder
        case archiveCreate, archiveExtract, editorUpload, permanentDelete, undo
    }

    public enum Conflict: Codable, Equatable, Sendable {
        case createNew
        case replace(OperationObservation)
        case mergeDirectory(OperationObservation)
        case skip
    }

    public let id: OperationItemID
    public let action: Action
    public let sources: [OperationLocation]
    public let destination: OperationLocation?
    public let sourceObservations: [OperationObservation]
    public let conflict: Conflict
    public let children: [OperationItemID]
    public let reverses: OperationItemID?
    public let archiveFormat: String?

    public init(
        id: OperationItemID, action: Action, sources: [OperationLocation],
        destination: OperationLocation?, sourceObservations: [OperationObservation],
        conflict: Conflict, children: [OperationItemID] = [],
        reverses: OperationItemID? = nil, archiveFormat: String? = nil
    ) {
        self.id = id
        self.action = action
        self.sources = sources
        self.destination = destination
        self.sourceObservations = sourceObservations
        self.conflict = conflict
        self.children = children
        self.reverses = reverses
        self.archiveFormat = archiveFormat
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
