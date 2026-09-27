import DetoursProcess
import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func prepareImportedTree(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let accepted = try journal.read(identity.id)
        if let receipt = accepted.receipt, [.readyToCommit, .committed, .terminal].contains(receipt.phase) { return receipt }
        guard let intent = accepted.intent, intent.action == .copy, let expected = intent.treeProof,
              let original = intent.sourceManifest, let destination = intent.destination,
              let record = accepted.workspace, let received = accepted.receipt, received.phase == .payloadReceived,
              received.contentVerified, let archive = received.preparedPayload, archive.observation.kind == .file else {
            throw OperationContractError.invalidReceipt
        }
        let parent = try resolve(destination).directory
        let workspace = try OperationWorkspace(parent: parent, record: record)
        let location = OperationLocation(account: journal.account, path: .unix(try parent.childPath(record.root.name)))
        let tree = OperationLocation(account: journal.account, path: .unix(try workspace.directory.childPath(Data("tree".utf8))))
        let preparation = ServerPayloadPreparation(workspace: workspace, location: location, payload: tree)
        do {
            try requirePreparationDestination(intent)
            try journal.record(.init(id: identity.id, account: journal.account, epoch: journal.epoch,
                intentDigest: identity.intentDigest, revision: received.revision + 1, phase: .preparing, outcome: .running,
                preparedPayload: archive, plannedPaths: received.plannedPaths, measuredBytes: received.measuredBytes,
                recovery: received.recovery), ownership: ownership)
            let input = try await treeCopyManifest(archive.location, identity: identity, ownership: ownership, measuredBefore: 0)
            guard let inputRoot = input.entries.first?.observation, inputRoot == archive.observation else {
                throw OperationFilesystemError.identityChanged
            }
            try workspace.validateManifest(input, root: Data("payload".utf8))
            try journal.recordManifests(identity.id, source: original, payload: nil, archiveInputs: input, ownership: ownership)
            let reader = ServerArchiveExtractionReader(service: self, identity: identity, ownership: ownership,
                input: archive, format: .zip, password: nil)
            let listed = try await reader.read(measuredBefore: input.proof.byteCount)
            let plan = try ServerArchiveExtractionPlan(listed.members, rootName: "tree")
            try await allocateExtractionMembers(plan, preparation: preparation, identity: identity, ownership: ownership)
            let extracted = try await reader.read(measuredBefore: listed.measured, output: { member in
                guard plan.members.indices.contains(Int(member.index)), plan.members[Int(member.index)] == member,
                      let name = plan.outputs[member.index] else { throw OperationFilesystemError.identityChanged }
                return try preparation.workspace.openEmptyFileForWriting(named: name)
            })
            guard extracted.members == plan.members else { throw OperationFilesystemError.identityChanged }
            try await finishExtractionMembers(plan, preparation: preparation, identity: identity, ownership: ownership)
            let payload = try await treeCopyManifest(tree, identity: identity, ownership: ownership, measuredBefore: extracted.measured)
            let inputAfter = try await treeCopyManifest(archive.location, identity: identity, ownership: ownership,
                measuredBefore: try extractionMeasured(extracted.measured, adding: payload.proof.byteCount))
            guard inputAfter == input, payload.proof == expected, let root = payload.entries.first?.observation,
                  root.kind == .directory else { throw OperationFilesystemError.identityChanged }
            try workspace.validateManifest(payload, root: Data("tree".utf8))
            try journal.recordManifests(identity.id, source: original, payload: payload, archiveInputs: input, ownership: ownership)
            let verified = OperationObservation(identity: root.identity, kind: root.kind, version: root.version,
                byteCount: root.byteCount, sha256: payload.proof.sha256, linkTarget: root.linkTarget, contentVersion: root.contentVersion)
            let ready = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
                intentDigest: identity.intentDigest, revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1,
                phase: .readyToCommit, outcome: .running, contentVerified: true,
                preparedPayload: .init(location: tree, observation: verified), recovery: [
                    .init(identity: record.root.identity, purpose: .scratch, original: nil, knownLocation: location, possibleLocations: [location]),
                    .init(identity: root.identity, purpose: .scratch, original: nil, knownLocation: tree, possibleLocations: [tree]),
                ])
            try journal.record(ready, ownership: ownership)
            return ready
        } catch {
            try await failPreparation(identity, preparation: preparation, ownership: ownership, failure: error)
            throw error
        }
    }
}
