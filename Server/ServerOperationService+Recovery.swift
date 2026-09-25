import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func reconcile(_ snapshot: OperationJournal.Snapshot) throws -> OperationJournal.Snapshot {
        guard let receipt = snapshot.receipt,
              [.preparing, .committing].contains(receipt.phase) || receipt.outcome == .unknown,
              let ownership = try journal.tryAcquireItem(snapshot.id) else { return snapshot }
        defer { withExtendedLifetime(ownership) {} }
        let current = try journal.read(snapshot.id)
        guard current == snapshot else { return current }
        guard let intent = current.intent, intent.conflict == .createNew,
              let destination = intent.destination, let payload = receipt.preparedPayload else {
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
        var recovery = receipt.recovery
        var confirmed = false
        var failure: String?
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
            recovery: recovery, children: receipt.children,
            failure: failure ?? (confirmed ? nil : "Recorded object identity and content do not prove publication.")
        )
        try journal.record(result, ownership: ownership)
        return try journal.read(current.id)
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
