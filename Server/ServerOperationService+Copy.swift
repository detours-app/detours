import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func prepareCopy(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        let initial = try status(identity)
        if let kind = initial.intent?.sourceObservations.first?.kind, [.directory, .symbolicLink].contains(kind) {
            return try await prepareTreeCopy(identity)
        }
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let accepted = try journal.read(identity.id)
        guard accepted.receipt == nil, let intent = accepted.intent, [.copy, .move].contains(intent.action),
              intent.sources.count == 1, intent.sourceObservations.count == 1,
              intent.sourceObservations[0].kind == .file else { throw OperationFilesystemError.unsupported }
        do {
            let observed = try await proveSource(intent, ownership: ownership)
            guard let hash = observed.sha256 else { throw OperationContractError.invalidReceipt }
            let source = try resolve(intent.sources[0])
            let input = try source.directory.openObservedFile(source.name, expected: observed)
            defer { try? input.close() }
            return try await prepareOwned(
                journal.read(identity.id), ownership: ownership,
                input: .sourceFile(input, source.directory, source.name, observed),
                proof: OperationContentProof(byteCount: observed.byteCount, sha256: hash)
            )
        } catch {
            let current = try journal.read(identity.id)
            if current.workspace == nil {
                try journal.record(OperationReceipt(
                    id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                    revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal, outcome: .failedUnchanged,
                    failure: String(describing: error)
                ), ownership: ownership)
            }
            throw error
        }
    }
}
