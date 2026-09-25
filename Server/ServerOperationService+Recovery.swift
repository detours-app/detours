import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func reconcile(_ snapshot: OperationJournal.Snapshot) throws -> OperationJournal.Snapshot {
        guard let receipt = snapshot.receipt,
              receipt.phase == .committing || receipt.outcome == .unknown,
              let ownership = try journal.tryAcquireItem(snapshot.id) else { return snapshot }
        defer { withExtendedLifetime(ownership) {} }
        let current = try journal.read(snapshot.id)
        guard current == snapshot, let intent = current.intent, intent.conflict == .createNew,
              let destination = intent.destination, let payload = receipt.preparedPayload,
              payload.observation.kind == .file, let hash = payload.observation.sha256 else { return current }
        var effects = receipt.effects
        var recovery = receipt.recovery
        var confirmed = false
        var failure: String?
        do {
            let source = try inspect(payload.location, expected: nil)
            let target = try inspect(destination, expected: payload.observation)
            if case .missing = source, case .found(let observed) = target,
               observed.identity == payload.observation.identity, observed.sha256 == hash,
               observed.byteCount == payload.observation.byteCount {
                effects.append(OperationEffect(location: destination, observation: observed))
                recovery.removeAll { $0.purpose == .scratch && $0.identity == payload.observation.identity }
                confirmed = true
            }
        } catch { failure = String(describing: error) }
        let result = OperationReceipt(
            id: current.id, account: journal.account, epoch: journal.epoch, intentDigest: current.intentDigest,
            revision: receipt.revision + 1, phase: .terminal,
            outcome: confirmed ? (intent.action == .move ? .partial : .committed) : .unknown,
            effects: effects, sourceDisposition: intent.action == .move ? .unknown : receipt.sourceDisposition,
            contentVerified: confirmed, preparedPayload: confirmed ? nil : payload,
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
        if let expected, case .found(let observation) = lookup,
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
