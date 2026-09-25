import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func prepareTreeCopy(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let accepted = try journal.read(identity.id)
        if let receipt = accepted.receipt, [.readyToCommit, .committed, .terminal].contains(receipt.phase) { return receipt }
        guard accepted.receipt == nil, let intent = accepted.intent, [.copy, .move].contains(intent.action),
              intent.sources.count == 1, intent.sourceObservations.count == 1,
              [.directory, .symbolicLink].contains(intent.sourceObservations[0].kind), let destination = intent.destination else {
            throw OperationContractError.invalidReceipt
        }
        var preparation: ServerPayloadPreparation?
        do {
            try requirePreparationDestination(intent)
            let source = intent.sources[0]
            let manifest = try await treeCopyManifest(source, identity: identity, ownership: ownership, measuredBefore: 0)
            guard let root = manifest.entries.first?.observation else { throw OperationContractError.invalidReceipt }
            let expected = intent.sourceObservations[0]
            guard root.identity == expected.identity, root.version == expected.version, root.kind == expected.kind,
                  root.linkTarget == expected.linkTarget, expected.sha256 == nil || expected.sha256 == manifest.proof.sha256,
                  intent.payloadProof == nil || intent.payloadProof == manifest.proof else { throw OperationFilesystemError.identityChanged }
            guard manifest.proof.byteCount <= UInt64.max / 4 else { throw OperationFilesystemError.unsupported }
            let target = try resolve(destination)
            guard !manifest.entries.contains(where: { $0.observation.kind == .directory && $0.observation.identity == target.directory.identity }) else {
                throw OperationFilesystemError.unsupported
            }
            try journal.recordManifests(identity.id, source: manifest, payload: nil, ownership: ownership)
            let allocated = try await allocatePreparation(identity, target: target.directory, ownership: ownership)
            preparation = allocated
            var copied: UInt64 = 0
            for entry in manifest.entries {
                let relative = entry.relativePath.isEmpty ? Data("payload".utf8) : Data("payload/".utf8) + entry.relativePath
                let output = try await createTreeMember(relative, observation: entry.observation, preparation: allocated,
                                                        identity: identity, ownership: ownership)
                if let output {
                    let sourceEffect = OperationEffect(location: try treeMemberLocation(source, relative: entry.relativePath),
                                                       observation: entry.observation)
                    try await treeCopyFile(sourceEffect, output: output, identity: identity, ownership: ownership,
                                           measuredBefore: manifest.proof.byteCount + copied)
                    copied += entry.observation.byteCount
                }
            }
            for entry in manifest.entries.reversed() where entry.observation.kind == .directory {
                guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
                let origin = try resolve(treeMemberLocation(source, relative: entry.relativePath))
                let target = try resolve(treeMemberLocation(allocated.payload, relative: entry.relativePath))
                let sourceDirectory = try OperationDirectory(path: origin.directory.childPath(origin.name))
                guard sourceDirectory.identity == entry.observation.identity else { throw OperationFilesystemError.identityChanged }
                _ = try OperationWorkspace(parent: resolve(destination).directory, record: allocated.workspace.record)
                let destinationDirectory = try OperationDirectory(path: target.directory.childPath(target.name))
                let relative = entry.relativePath.isEmpty ? Data("payload".utf8) : Data("payload/".utf8) + entry.relativePath
                guard allocated.workspace.record.objects.contains(where: {
                    $0.name == relative && $0.kind == .directory && $0.identity == destinationDirectory.identity
                }) else { throw OperationFilesystemError.identityChanged }
                try sourceDirectory.copyMetadata(to: destinationDirectory)
            }
            let payload = try await treeCopyManifest(allocated.payload, identity: identity, ownership: ownership,
                                                     measuredBefore: manifest.proof.byteCount + copied)
            let finalSource = try await treeCopyManifest(source, identity: identity, ownership: ownership,
                                                         measuredBefore: manifest.proof.byteCount + copied + payload.proof.byteCount)
            try allocated.workspace.validateManifest(payload, root: Data("payload".utf8))
            guard finalSource == manifest, payload.proof == manifest.proof,
                  let observed = payload.entries.first?.observation else { throw OperationFilesystemError.identityChanged }
            try journal.recordManifests(identity.id, source: manifest, payload: payload, ownership: ownership)
            let verified = OperationObservation(identity: observed.identity, kind: observed.kind, version: observed.version,
                                                byteCount: observed.byteCount, sha256: payload.proof.sha256,
                                                linkTarget: observed.linkTarget, contentVersion: observed.contentVersion)
            let result = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1, phase: .readyToCommit, outcome: .running,
                sourceDisposition: intent.action == .move ? .present : .notRequired,
                contentVerified: true, preparedPayload: OperationEffect(location: allocated.payload, observation: verified),
                measuredBytes: manifest.proof.byteCount * 4, recovery: [
                    .init(identity: allocated.workspace.record.root.identity, purpose: .scratch, original: nil,
                          knownLocation: allocated.location, possibleLocations: [allocated.location]),
                    .init(identity: observed.identity, purpose: .scratch, original: nil,
                          knownLocation: allocated.payload, possibleLocations: [allocated.payload]),
                ]
            )
            try journal.record(result, ownership: ownership)
            return result
        } catch {
            try await failPreparation(identity, preparation: preparation, ownership: ownership, failure: error)
            throw error
        }
    }

    private func createTreeMember(_ relative: Data, observation: OperationObservation, preparation: ServerPayloadPreparation,
                                  identity: OperationRequestIdentity, ownership: OperationJournal.Ownership) async throws -> FileHandle? {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
        let output: FileHandle?
        switch observation.kind {
        case .file: output = try preparation.workspace.createFile(named: relative)
        case .directory:
            try preparation.workspace.createDirectory(named: relative)
            output = nil
        case .symbolicLink:
            guard let target = observation.linkTarget else { throw OperationContractError.invalidReceipt }
            try preparation.workspace.createSymbolicLink(named: relative, target: target)
            output = nil
        }
        try journal.recordWorkspace(preparation.workspace.record, ownership: ownership)
        return output
    }
}
