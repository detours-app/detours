import Darwin
import Foundation
import RemoteOperationSupport

struct LocalTransferService: Sendable {
    let journal: OperationJournal
    let afterSourceMove: (@Sendable (OperationLocation) throws -> Void)?

    init(journal: OperationJournal, afterSourceMove: (@Sendable (OperationLocation) throws -> Void)? = nil) {
        self.journal = journal
        self.afterSourceMove = afterSourceMove
    }

    func endpoint() -> RemoteOperationCoordinator.Endpoint {
        let session = RemoteHostSession(transport: LocalTransferTransport(service: self), publish: { _, _ in })
        return .init(session: session, request: { try await reply($0) }, upload: { url, identity in
            try await LocalTransferPublication.prepare(url, identity: identity, journal: journal)
        })
    }

    func reply(_ request: OperationRequest) async throws -> OperationReply {
        switch request {
        case .handshake(let version, let schema, let required):
            try journal.validateEpoch()
            let handshake = OperationHandshake(version: OperationHandshake.protocolVersion, schemaVersion: OperationHandshake.journalSchema,
                capabilities: Set(OperationCapability.allCases), account: journal.account, epoch: journal.epoch)
            guard version == handshake.version else { return .incompatible(.protocolVersion(expected: handshake.version, actual: version)) }
            guard schema == handshake.schemaVersion else { return .incompatible(.journalSchema(expected: handshake.schemaVersion, actual: schema)) }
            let missing = required.subtracting(handshake.capabilities)
            return missing.isEmpty ? .handshake(handshake) : .incompatible(.missingCapabilities(missing))
        case .lookup(let location), .sourceProof(let location), .sourceManifest(let location):
            guard location.account == journal.account else { return .incompatible(.accountMismatch) }
            try journal.validateEpoch()
            do {
                let target = try LocalTransferPublication.split(location)
                let directory = try OperationDirectory(path: target.parent)
                switch request {
                case .sourceProof:
                    return .lookup(.found(try directory.proveObject(target.name, progress: { _ in try Task.checkCancellation() })))
                case .sourceManifest:
                    return .manifest(.found(try directory.manifest(target.name, progress: { _ in try Task.checkCancellation() })))
                default: return .lookup(try directory.lookup(target.name))
                }
            } catch OperationFilesystemError.system(let code) {
                let missing = code == ENOENT
                guard missing || code == EACCES || code == EPERM else { throw OperationFilesystemError.system(code) }
                if case .sourceManifest = request { return .manifest(missing ? .missing : .denied) }
                return .lookup(missing ? .missing : .denied)
            }
        case .archiveLayout(let location, _, _):
            guard location.account == journal.account else { return .incompatible(.accountMismatch) }
            try journal.validateEpoch()
            return .archiveLayout(.unsupported)
        case .accept(let identity, let intent):
            try validate(identity)
            guard identity.id == intent.id, try OperationContentProof.data(intent.canonicalData()).sha256 == identity.intentDigest,
                  [.copy, .trash, .restore].contains(intent.action) else { throw OperationContractError.invalidReceipt }
            let ownership = try await journal.acquireItem(identity.id)
            return .accepted(try journal.accept(intent, digest: identity.intentDigest, ownership: ownership))
        case .status(let identity):
            try validate(identity)
            let current = try read(identity)
            guard let receipt = current.receipt, [.preparing, .committing, .rollingBack].contains(receipt.phase),
                  let ownership = try journal.tryAcquireItem(identity.id) else { return .status(current) }
            guard try read(identity) == current else { return .status(try read(identity)) }
            _ = try record(identity, phase: .terminal, outcome: .unknown, ownership: ownership,
                           failure: "Local transfer stopped before its result was recorded.")
            return .status(try journal.read(identity.id))
        case .cancel(let identity):
            _ = try read(identity)
            try journal.requestCancellation(identity.id)
            return .cancellationRecorded(identity)
        case .acknowledge(let identity, let retainingUndo):
            _ = try read(identity)
            let ownership = try await journal.acquireItem(identity.id)
            try journal.acknowledge(identity.id, retainingUndo: retainingUndo, ownership: ownership)
            return .acknowledged(identity)
        case .commit(let identity): return .receipt(try await commit(identity))
        case .execute(let identity):
            if try read(identity).intent?.action == .restore { return .receipt(try await restore(identity)) }
            return .receipt(try await trash(identity))
        default: throw FileProviderError.unsupportedOperation("Unsupported local transfer request.")
        }
    }

    func read(_ identity: OperationRequestIdentity) throws -> OperationJournal.Snapshot {
        try validate(identity)
        let snapshot = try journal.read(identity.id)
        guard snapshot.intentDigest == identity.intentDigest else { throw OperationContractError.intentMismatch }
        return snapshot
    }

    func validate(_ identity: OperationRequestIdentity) throws {
        try journal.validateEpoch()
        guard identity.account == journal.account, identity.epoch == journal.epoch else { throw OperationContractError.identityMismatch }
    }

    @discardableResult
    func record(_ identity: OperationRequestIdentity, phase: OperationPhase, outcome: OperationOutcome,
                ownership: OperationJournal.Ownership, recovery: [OperationRecoveryReference]? = nil,
                failure: String? = nil, sourceDisposition: OperationReceipt.SourceDisposition? = nil,
                effects: [OperationEffect]? = nil) throws -> OperationReceipt {
        let current = try read(identity).receipt
        let receipt = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
            intentDigest: identity.intentDigest, revision: (current?.revision ?? 0) + 1, phase: phase, outcome: outcome,
            effects: effects ?? current?.effects ?? [], sourceDisposition: sourceDisposition ?? current?.sourceDisposition ?? .notRequired,
            contentVerified: current?.contentVerified ?? false, preparedPayload: current?.preparedPayload,
            plannedPaths: current?.plannedPaths, measuredBytes: current?.measuredBytes,
            recovery: recovery ?? current?.recovery ?? [], children: current?.children ?? [], failure: failure)
        try journal.record(receipt, ownership: ownership)
        return receipt
    }
}

private struct LocalTransferTransport: RemoteHostSessionTransport {
    let service: LocalTransferService
    func handshake(generation: UInt64,
                   onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        guard case .handshake(let handshake) = try await service.reply(.handshake) else { throw RemoteHostSessionError.invalidHandshake }
        return handshake
    }
    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}
