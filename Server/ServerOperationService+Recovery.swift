import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func reconcile(_ snapshot: OperationJournal.Snapshot) throws -> OperationJournal.Snapshot {
        guard let receipt = snapshot.receipt,
              [.preparing, .committing, .rollingBack].contains(receipt.phase) || receipt.outcome == .unknown
                || receipt.recovery.contains(where: { $0.purpose == .displacedOriginal && $0.knownLocation == nil }),
              let ownership = try journal.tryAcquireItem(snapshot.id) else { return snapshot }
        defer { withExtendedLifetime(ownership) {} }
        let current = try journal.read(snapshot.id)
        guard current == snapshot else { return current }
        if receipt.outcome == .committed {
            let recovery = locateOriginals(receipt.recovery)
            guard recovery != receipt.recovery else { return current }
            try journal.record(OperationReceipt(
                id: receipt.id, account: receipt.account, epoch: receipt.epoch, intentDigest: receipt.intentDigest,
                revision: receipt.revision + 1, phase: receipt.phase, outcome: receipt.outcome, effects: receipt.effects,
                sourceDisposition: receipt.sourceDisposition, contentVerified: receipt.contentVerified,
                recovery: recovery, children: receipt.children,
                failure: recovery.contains { $0.purpose == .displacedOriginal && $0.knownLocation == nil }
                    ? "The displaced original's current location could not be confirmed." : nil
            ), ownership: ownership)
            return try journal.read(current.id)
        }
        let supportsPublication: Bool
        switch current.intent?.conflict {
        case .some(.createNew), .some(.replace): supportsPublication = true
        default: supportsPublication = false
        }
        let recordedDestination = current.intent?.destination
            ?? (current.intent?.action == .trash ? receipt.plannedPaths?.first : nil)
        guard let intent = current.intent, supportsPublication,
              let destination = recordedDestination, let payload = receipt.preparedPayload else {
            if receipt.outcome == .unknown { return current }
            try journal.record(OperationReceipt(
                id: current.id, account: journal.account, epoch: journal.epoch, intentDigest: current.intentDigest,
                revision: receipt.revision + 1, phase: .terminal, outcome: .unknown,
                effects: receipt.effects, sourceDisposition: receipt.sourceDisposition,
                preparedPayload: receipt.preparedPayload, plannedPaths: receipt.plannedPaths,
                recovery: receipt.recovery, children: receipt.children,
                failure: "The worker stopped without enough recorded object evidence to prove its result."
            ), ownership: ownership)
            return try journal.read(current.id)
        }
        let sourceMutation = receipt.recovery.contains { $0.purpose == .source && $0.identity == payload.observation.identity }
        var effects = receipt.effects
        var recovery = locateOriginals(receipt.recovery)
        var confirmed = false
        var failure: String? = recovery.contains { $0.purpose == .displacedOriginal && $0.knownLocation == nil }
            ? "The displaced original's current location could not be confirmed." : nil
        do {
            let source = try inspect(payload.location, expected: nil)
            let target = try inspect(destination, expected: payload.observation)
            if case .missing = source, case .found(let observed) = target,
               observed.identity == payload.observation.identity, observed.kind == payload.observation.kind,
               observed.linkTarget == payload.observation.linkTarget,
               observed.byteCount == payload.observation.byteCount,
               (sourceMutation && payload.observation.contentVersion != nil
                && observed.contentVersion == payload.observation.contentVersion
                && (payload.observation.sha256 == nil || observed.sha256 == payload.observation.sha256))
                || (!sourceMutation && payload.observation.sha256 != nil && observed.sha256 == payload.observation.sha256) {
                effects.append(OperationEffect(location: destination, observation: observed))
                recovery.removeAll { [.scratch, .source].contains($0.purpose) && $0.identity == payload.observation.identity }
                if intent.action == .trash {
                    recovery.append(OperationRecoveryReference(identity: observed.identity, purpose: .sourceTrash,
                                                               original: payload.location, knownLocation: destination,
                                                               possibleLocations: [destination]))
                }
                confirmed = true
            }
        } catch { failure = String(describing: error) }
        let result = OperationReceipt(
            id: current.id, account: journal.account, epoch: journal.epoch, intentDigest: current.intentDigest,
            revision: receipt.revision + 1, phase: .terminal,
            outcome: confirmed ? (intent.action == .move && !sourceMutation ? .partial : .committed) : .unknown,
            effects: effects, sourceDisposition: sourceMutation && confirmed ? .confirmed
                : (intent.action == .move ? .unknown : receipt.sourceDisposition),
            contentVerified: confirmed && payload.observation.sha256 != nil, preparedPayload: confirmed ? nil : payload,
            plannedPaths: receipt.plannedPaths, recovery: recovery, children: receipt.children,
            failure: failure ?? (confirmed ? nil : "Recorded object identity and content do not prove publication.")
        )
        try journal.record(result, ownership: ownership)
        return try journal.read(current.id)
    }

    private func locateOriginals(_ references: [OperationRecoveryReference]) -> [OperationRecoveryReference] {
        references.map { reference in
            guard reference.purpose == .displacedOriginal else { return reference }
            var known: OperationLocation?
            for location in reference.possibleLocations {
                do {
                    if case .found(let observed) = try inspect(location, expected: nil), observed.identity == reference.identity {
                        known = location
                        break
                    }
                } catch { continue }
            }
            return OperationRecoveryReference(identity: reference.identity, purpose: reference.purpose,
                                              original: reference.original, knownLocation: known,
                                              possibleLocations: reference.possibleLocations)
        }
    }

    private func inspect(_ location: OperationLocation,
                         expected: OperationObservation?) throws -> OperationLookup<OperationObservation> {
        guard location.account == journal.account, case .unix(let bytes) = location.path,
              bytes.first == 47, let slash = bytes.lastIndex(of: 47), slash < bytes.index(before: bytes.endIndex) else {
            throw OperationFilesystemError.invalidPath
        }
        let parent = slash == bytes.startIndex ? Data([47]) : Data(bytes[..<slash])
        let name = Data(bytes[bytes.index(after: slash)...])
        let directory = try OperationDirectory(path: parent)
        let lookup = try directory.lookup(name)
        if let expected, expected.sha256 != nil, case .found(let observation) = lookup,
           observation.identity == expected.identity, observation.kind == .file {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            return .found(try directory.proveFile(name) { _ in
                guard clock.now < deadline else { throw OperationJournalError.busy }
            })
        }
        return lookup
    }
}
