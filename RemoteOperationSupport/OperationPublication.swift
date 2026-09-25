import Foundation

public enum OperationPublication {
    public static func publish(journal: OperationJournal, id: OperationItemID,
                               ownership: OperationJournal.Ownership) async throws -> OperationReceipt {
        let accepted = try journal.read(id)
        guard let intent = accepted.intent, let destination = intent.destination,
              destination.account == journal.account,
              let ready = accepted.receipt, ready.phase == .readyToCommit, ready.contentVerified,
              let payload = ready.preparedPayload, payload.location.account == journal.account,
              ready.recovery.contains(where: { $0.purpose == .scratch && $0.identity == payload.observation.identity
                  && $0.knownLocation == payload.location }) else {
            throw OperationContractError.invalidReceipt
        }
        if payload.observation.kind == .file, payload.observation.sha256 == nil {
            throw OperationContractError.invalidReceipt
        }
        switch intent.conflict {
        case .createNew: break
        case .replace(let original):
            guard ready.recovery.contains(where: {
                $0.purpose == .displacedOriginal && $0.identity == original.identity && $0.knownLocation != nil
            }) else { throw OperationContractError.invalidReceipt }
        case .mergeDirectory, .skip: throw OperationContractError.invalidReceipt
        }
        let source = try split(payload.location)
        let target = try split(destination)
        let sourceDirectory = try OperationDirectory(path: source.parent)
        let targetDirectory = try OperationDirectory(path: target.parent)
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        guard try journal.read(id) == accepted else { throw OperationContractError.conflictingRevision }
        guard try !journal.cancellationRequested(id) else { throw OperationContractError.cancelled }
        try Task.checkCancellation()

        let uncertain = OperationRecoveryReference(
            identity: payload.observation.identity, purpose: .scratch, original: nil, knownLocation: nil,
            possibleLocations: [payload.location, destination]
        )
        let recovery = ready.recovery.filter { $0.identity != payload.observation.identity } + [uncertain]
        let committing = OperationReceipt(
            id: id, account: journal.account, epoch: journal.epoch, intentDigest: accepted.intentDigest,
            revision: ready.revision + 1, phase: .committing, outcome: .running, effects: ready.effects,
            sourceDisposition: ready.sourceDisposition, contentVerified: true, preparedPayload: payload,
            recovery: recovery, children: ready.children
        )
        try journal.record(committing, ownership: ownership)
        let observation = try sourceDirectory.moveExclusive(source.name, to: targetDirectory, named: target.name,
                                                             expected: payload.observation)
        let confirmed = OperationObservation(identity: observation.identity, kind: observation.kind,
                                             version: observation.version, byteCount: observation.byteCount,
                                             sha256: payload.observation.sha256, linkTarget: observation.linkTarget,
                                             contentVersion: observation.contentVersion)
        let committed = OperationReceipt(
            id: id, account: journal.account, epoch: journal.epoch, intentDigest: accepted.intentDigest,
            revision: committing.revision + 1, phase: .committed,
            outcome: intent.action == .move ? .running : .committed,
            effects: ready.effects + [OperationEffect(location: destination, observation: confirmed)],
            sourceDisposition: intent.action == .move ? .present : ready.sourceDisposition,
            contentVerified: true, preparedPayload: nil,
            recovery: ready.recovery.filter { $0.identity != payload.observation.identity }, children: ready.children
        )
        try journal.record(committed, ownership: ownership)
        return committed
    }

    private static func split(_ location: OperationLocation) throws -> (parent: Data, name: Data) {
        guard case .unix(let bytes) = location.path, bytes.first == 47,
              let slash = bytes.lastIndex(of: 47), slash < bytes.index(before: bytes.endIndex) else {
            throw OperationFilesystemError.invalidPath
        }
        let parent = slash == bytes.startIndex ? Data([47]) : Data(bytes[..<slash])
        return (parent, Data(bytes[bytes.index(after: slash)...]))
    }
}
