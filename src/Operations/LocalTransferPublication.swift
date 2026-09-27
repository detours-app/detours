import Foundation
import RemoteOperationSupport

enum LocalTransferPublication {
    static func prepare(_ staged: URL, identity: OperationRequestIdentity, journal: OperationJournal) async throws -> OperationReceipt {
        let ownership = try await journal.acquireItem(identity.id)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try prepareOwned(staged, identity: identity, journal: journal, ownership: ownership)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func prepareOwned(_ staged: URL, identity: OperationRequestIdentity, journal: OperationJournal,
                                     ownership: OperationJournal.Ownership) throws -> OperationReceipt {
        let accepted = try journal.read(identity.id)
        guard accepted.account == identity.account, accepted.epoch == identity.epoch,
              accepted.intentDigest == identity.intentDigest else { throw OperationContractError.identityMismatch }
        if let receipt = accepted.receipt { return receipt }
        guard let intent = accepted.intent, intent.action == .copy, let destination = intent.destination,
              destination.account == journal.account else { throw OperationContractError.invalidReceipt }
        let target = try split(destination)
        let parent = try OperationDirectory(path: target.parent)
        let name = OperationWorkspace.plannedName(for: identity.id)
        let root = OperationLocation(account: journal.account, path: .unix(try parent.childPath(name)))
        let planned = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
            intentDigest: identity.intentDigest, revision: 1, phase: .preparing, outcome: .running, plannedPaths: [root])
        try journal.record(planned, ownership: ownership)
        let workspace = try OperationWorkspace(parent: parent, id: identity.id, plannedName: name)
        try journal.recordWorkspace(workspace.record, ownership: ownership)
        do {
            try checkCancellation(identity.id, journal: journal)
            let sourceDirectory = try OperationDirectory(path: Data(staged.deletingLastPathComponent().path.utf8))
            let sourceName = Data(staged.lastPathComponent.utf8)
            let manifest = try sourceDirectory.manifest(sourceName) { _ in try checkCancellation(identity.id, journal: journal) }
            guard let source = manifest.entries.first?.observation else { throw OperationContractError.invalidReceipt }
            if source.kind == .directory {
                guard intent.treeProof == manifest.proof else { throw OperationFilesystemError.identityChanged }
            } else {
                guard source.kind == .file, intent.payloadProof?.sha256 == source.sha256,
                      intent.payloadProof?.byteCount == source.byteCount else { throw OperationFilesystemError.identityChanged }
            }
            for entry in manifest.entries {
                try checkCancellation(identity.id, journal: journal)
                let member = Data("payload".utf8) + (entry.relativePath.isEmpty ? Data() : Data([47]) + entry.relativePath)
                switch entry.observation.kind {
                case .directory: try workspace.createDirectory(named: member)
                case .symbolicLink:
                    guard let link = entry.observation.linkTarget else { throw OperationContractError.invalidReceipt }
                    try workspace.createSymbolicLink(named: member, target: link)
                case .file:
                    let output = try workspace.createFile(named: member)
                    try journal.recordWorkspace(workspace.record, ownership: ownership)
                    let path = Data(staged.path.utf8) + (entry.relativePath.isEmpty ? Data() : Data([47]) + entry.relativePath)
                    let origin = try split(.init(account: journal.account, path: .unix(path)))
                    let directory = try OperationDirectory(path: origin.parent)
                    let input = try directory.openObservedFile(origin.name, expected: entry.observation)
                    defer { try? input.close(); try? output.close() }
                    while true {
                        try checkCancellation(identity.id, journal: journal)
                        guard let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty else { break }
                        try output.write(contentsOf: bytes)
                    }
                    try output.synchronize()
                }
                try journal.recordWorkspace(workspace.record, ownership: ownership)
            }
            for entry in manifest.entries.reversed() {
                guard let relative = String(data: entry.relativePath, encoding: .utf8) else { throw OperationFilesystemError.invalidPath }
                let url = relative.isEmpty ? staged : staged.appendingPathComponent(relative)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let mode = attributes[.posixPermissions] as? NSNumber,
                      let modified = attributes[.modificationDate] as? Date else { throw OperationFilesystemError.unsupported }
                let member = Data("payload".utf8) + (entry.relativePath.isEmpty ? Data() : Data([47]) + entry.relativePath)
                try workspace.applyMetadata(named: member, mode: mode.uint32Value, modified: modified)
            }
            let payload = try workspace.directory.manifest(Data("payload".utf8)) { _ in try checkCancellation(identity.id, journal: journal) }
            guard payload.proof == manifest.proof,
                  try sourceDirectory.manifest(sourceName, progress: { _ in try checkCancellation(identity.id, journal: journal) }) == manifest,
                  let observed = payload.entries.first?.observation else { throw OperationFilesystemError.identityChanged }
            try workspace.validateManifest(payload, root: Data("payload".utf8))
            try journal.recordManifests(identity.id, source: intent.sourceManifest ?? manifest, payload: payload, ownership: ownership)
            let location = OperationLocation(account: journal.account, path: .unix(try workspace.directory.childPath(Data("payload".utf8))))
            let verified = OperationObservation(identity: observed.identity, kind: observed.kind, version: observed.version,
                byteCount: observed.byteCount, sha256: observed.kind == .file ? observed.sha256 : payload.proof.sha256,
                linkTarget: observed.linkTarget, contentVersion: observed.contentVersion)
            let ready = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
                intentDigest: identity.intentDigest, revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1,
                phase: .readyToCommit, outcome: .running, contentVerified: true,
                preparedPayload: .init(location: location, observation: verified), recovery: [
                    .init(identity: workspace.record.root.identity, purpose: .scratch, original: nil, knownLocation: root, possibleLocations: [root]),
                    .init(identity: observed.identity, purpose: .scratch, original: nil, knownLocation: location, possibleLocations: [location]),
                ])
            try journal.record(ready, ownership: ownership)
            return ready
        } catch {
            var failure = String(describing: error)
            var recovery: [OperationRecoveryReference] = []
            do { try workspace.removeScratch() } catch {
                failure += "; scratch cleanup: \(error)"
                recovery = [.init(identity: workspace.record.root.identity, purpose: .scratch,
                                  original: nil, knownLocation: root, possibleLocations: [root])]
            }
            let result = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
                intentDigest: identity.intentDigest, revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1,
                phase: .terminal, outcome: recovery.isEmpty ? .failedUnchanged : .partial, recovery: recovery, failure: failure)
            try journal.record(result, ownership: ownership)
            throw error
        }
    }

    static func split(_ location: OperationLocation) throws -> (parent: Data, name: Data) {
        guard case .unix(let bytes) = location.path, bytes.first == 47,
              let slash = bytes.lastIndex(of: 47), slash < bytes.index(before: bytes.endIndex) else {
            throw OperationFilesystemError.invalidPath
        }
        return (slash == bytes.startIndex ? Data([47]) : Data(bytes[..<slash]), Data(bytes[bytes.index(after: slash)...]))
    }

    static func checkCancellation(_ id: OperationItemID, journal: OperationJournal) throws {
        guard try !journal.cancellationRequested(id) else { throw OperationContractError.cancelled }
    }
}
