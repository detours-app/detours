import Foundation
import RemoteOperationSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension ServerOperationService {
    func execute(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let snapshot = try journal.read(identity.id)
        if let receipt = snapshot.receipt, receipt.phase == .terminal { return receipt }
        guard snapshot.receipt == nil, let intent = snapshot.intent else { throw OperationContractError.invalidReceipt }
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        var mutationStarted = false
        do {
            guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
            guard [.rename, .move, .createFolder].contains(intent.action), intent.conflict == .createNew,
                  let destination = intent.destination else { throw OperationFilesystemError.unsupported }
            let target = try resolve(destination)
            switch try target.directory.lookup(target.name) {
            case .missing: break
            case .found: throw OperationFilesystemError.system(EEXIST)
            case .denied: throw OperationFilesystemError.system(EACCES)
            case .disconnected: throw OperationFilesystemError.system(ENOTCONN)
            case .unsupported: throw OperationFilesystemError.unsupported
            }
            let source: (directory: OperationDirectory, name: Data)?
            let payload: OperationEffect?
            let recovery: [OperationRecoveryReference]
            if intent.action == .createFolder {
                guard intent.sources.isEmpty else { throw OperationContractError.invalidReceipt }
                source = nil
                payload = nil
                recovery = []
            } else {
                guard intent.sources.count == 1, intent.sourceObservations.count == 1 else {
                    throw OperationContractError.invalidReceipt
                }
                let resolved = try resolve(intent.sources[0])
                let expected = intent.sourceObservations[0]
                let observed = try resolved.directory.observe(resolved.name)
                guard observed.identity == expected.identity, observed.version == expected.version,
                      observed.kind == expected.kind, observed.linkTarget == expected.linkTarget else {
                    throw OperationFilesystemError.identityChanged
                }
                guard resolved.directory.identity.volume == target.directory.identity.volume else {
                    throw OperationFilesystemError.system(EXDEV)
                }
                source = resolved
                payload = OperationEffect(location: intent.sources[0], observation: expected)
                recovery = [OperationRecoveryReference(identity: expected.identity, purpose: .source,
                                                        original: intent.sources[0], knownLocation: nil,
                                                        possibleLocations: [intent.sources[0], destination])]
            }
            let committing = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: 1, phase: .committing, outcome: .running,
                sourceDisposition: source == nil ? .notRequired : .unknown, preparedPayload: payload,
                plannedPaths: [destination], recovery: recovery
            )
            try journal.record(committing, ownership: ownership)
            guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
            let observed: OperationObservation
            mutationStarted = true
            if let source, let payload {
                observed = try source.directory.moveExclusive(source.name, to: target.directory, named: target.name,
                                                               expected: payload.observation)
            } else {
                observed = try target.directory.createDirectory(target.name)
            }
            let result = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: 2, phase: .terminal, outcome: .committed,
                effects: [OperationEffect(location: destination, observation: observed)],
                sourceDisposition: source == nil ? .notRequired : .confirmed
            )
            try journal.record(result, ownership: ownership)
            return result
        } catch {
            let current = try journal.read(identity.id)
            if let receipt = current.receipt, receipt.outcome == .committed { return receipt }
            let result = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal,
                outcome: mutationStarted ? .unknown : .failedUnchanged,
                sourceDisposition: mutationStarted ? (current.receipt?.sourceDisposition ?? .unknown) : .notRequired,
                preparedPayload: current.receipt?.preparedPayload, plannedPaths: current.receipt?.plannedPaths,
                recovery: mutationStarted ? (current.receipt?.recovery ?? []) : [], failure: String(describing: error)
            )
            try journal.record(result, ownership: ownership)
            return result
        }
    }

    private func resolve(_ location: OperationLocation) throws -> (directory: OperationDirectory, name: Data) {
        guard location.account == journal.account, case .unix(let bytes) = location.path,
              bytes.first == 47, let slash = bytes.lastIndex(of: 47), slash < bytes.index(before: bytes.endIndex) else {
            throw OperationFilesystemError.invalidPath
        }
        let parent = slash == bytes.startIndex ? Data([47]) : Data(bytes[..<slash])
        return (try OperationDirectory(path: parent), Data(bytes[bytes.index(after: slash)...]))
    }
}
