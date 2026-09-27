import DetoursProcess
import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func allocateExtractionMembers(_ plan: ServerArchiveExtractionPlan, preparation: ServerPayloadPreparation,
                                   identity: OperationRequestIdentity, ownership: OperationJournal.Ownership) async throws {
        for name in plan.directories {
            try await mutateExtraction(preparation, identity: identity, ownership: ownership) {
                try preparation.workspace.createDirectory(named: name)
            }
        }
        for member in plan.members {
            guard let name = plan.outputs[member.index] else { continue }
            try await createArchiveOutput(preparation, name: name, identity: identity, ownership: ownership).close()
        }
    }

    func finishExtractionMembers(_ plan: ServerArchiveExtractionPlan, preparation: ServerPayloadPreparation,
                                 identity: OperationRequestIdentity, ownership: OperationJournal.Ownership) async throws {
        let intent = try journal.read(identity.id).intent
        let strictLinks = intent?.archiveFormat == ServerArchiveFormat.sevenZ.rawValue ||
            intent?.archiveFormat == ServerArchiveFormat.zip.rawValue && intent?.archiveEncrypted == true
        for member in plan.members where !member.directory && member.hardLink == nil {
            guard let name = plan.paths[member.index], let output = plan.outputs[member.index] else { throw SevenZipArchiveError.invalidEntry }
            let location = try treeMemberLocation(preparation.location, relative: output)
            let stored = try resolve(location)
            let observed = try stored.directory.observe(stored.name)
            guard observed.kind == .file,
                  preparation.workspace.record.objects.contains(where: { $0.name == output && $0.identity == observed.identity }) else {
                throw OperationFilesystemError.identityChanged
            }
            if member.symbolicLink != nil || member.mode & 0o170000 == 0o120000 {
                guard observed.byteCount <= 4096 else { throw SevenZipArchiveError.invalidEntry }
                let input = try stored.directory.openObservedFile(stored.name, expected: observed)
                defer { try? input.close() }
                let bytes = try input.read(upToCount: 4097) ?? Data()
                let target = member.symbolicLink.map { Data($0.utf8) } ?? bytes
                guard !target.isEmpty, !target.contains(0), member.symbolicLink == nil || bytes.isEmpty || bytes == target else {
                    throw SevenZipArchiveError.invalidEntry
                }
                if strictLinks {
                    guard let text = String(data: target, encoding: .utf8), ArchiveToolDiagnostics.firstUnsafeMemberPath([text]) == nil else {
                        throw SevenZipArchiveError.invalidEntry
                    }
                }
                try await mutateExtraction(preparation, identity: identity, ownership: ownership) {
                    try preparation.workspace.createSymbolicLink(named: name, target: target)
                }
            } else if let size = member.size, size != observed.byteCount { throw OperationFilesystemError.identityChanged }
        }
        var pending = plan.hardLinks
        while !pending.isEmpty {
            var completed: [UInt32] = []
            for (index, source) in pending.sorted(by: { $0.key < $1.key }) where pending[source] == nil {
                guard let name = plan.paths[index], let origin = plan.paths[source] else { throw SevenZipArchiveError.invalidEntry }
                try await mutateExtraction(preparation, identity: identity, ownership: ownership) {
                    try preparation.workspace.createHardLink(named: name, to: origin)
                }
                completed.append(index)
            }
            guard !completed.isEmpty else { throw SevenZipArchiveError.invalidEntry }
            for index in completed { pending.removeValue(forKey: index) }
        }
        let explicit = Set(plan.members.filter(\.directory).compactMap { plan.paths[$0.index] })
        for name in plan.directories.reversed() where !explicit.contains(name) {
            try await mutateExtraction(preparation, identity: identity, ownership: ownership) {
                try preparation.workspace.applyMetadata(named: name, mode: 0o755, modified: nil)
            }
        }
        for member in plan.members.reversed() {
            guard let name = plan.paths[member.index] else { continue }
            let mode = member.mode == 0 ? UInt32(member.directory ? 0o755 : 0o644) : member.mode
            try await mutateExtraction(preparation, identity: identity, ownership: ownership) {
                try preparation.workspace.applyMetadata(named: name, mode: mode, modified: member.modified)
            }
        }
    }

    private func mutateExtraction(_ preparation: ServerPayloadPreparation, identity: OperationRequestIdentity,
                                  ownership: OperationJournal.Ownership, change: () throws -> Void) async throws {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
        try change()
        try journal.recordWorkspace(preparation.workspace.record, ownership: ownership)
    }
}
