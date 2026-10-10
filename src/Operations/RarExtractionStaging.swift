import DetoursProcess
import Foundation
import RemoteOperationSupport

// Access is serial: preparation finishes before the main actor starts publication.
final class RarExtractionStaging: @unchecked Sendable {
    private final class OutputOwner: @unchecked Sendable {
        let workspace: OperationWorkspace
        init(_ workspace: OperationWorkspace) { self.workspace = workspace }
    }
    let volumes: RarVolumeSet
    let plan: RarExtractionPlan
    let workspace: OperationWorkspace
    let manifest: OperationManifest
    let payload = Data("payload".utf8)

    init(volumes: RarVolumeSet, password: String?, caseSensitive: Bool, availableBytes: Int64?,
         progress: @escaping @Sendable (UInt64) throws -> Void,
         beforeOutput: @escaping @Sendable () throws -> Void) throws {
        self.volumes = volumes
        let plan = try RarExtractionPlan(volumes.members, caseSensitive: caseSensitive)
        self.plan = plan
        if let availableBytes, availableBytes >= 0, plan.byteCount > UInt64(availableBytes) {
            throw POSIXError(.ENOSPC)
        }
        let workspace = try OperationWorkspace(parent: volumes.directory, id: .init(operation: UUID(), item: UUID()),
            plannedName: Data(".detours-extract-\(UUID().uuidString)".utf8))
        self.workspace = workspace
        let owner = OutputOwner(workspace)
        do {
            for name in plan.directories { try workspace.createDirectory(named: name) }
            for name in plan.outputs.values { try workspace.createFile(named: name).close() }
            let extracted = try volumes.read(password: password, output: { member in
                guard plan.members.indices.contains(Int(member.index)), plan.members[Int(member.index)] == member,
                      let name = plan.outputs[member.index] else { throw OperationFilesystemError.identityChanged }
                try beforeOutput()
                return try owner.workspace.openEmptyFileForWriting(named: name)
            }, progress: progress)
            guard extracted == plan.members else { throw OperationFilesystemError.identityChanged }
            try Self.finish(plan, workspace: workspace, progress: progress)
            try volumes.validate(progress: progress)
            let manifest = try workspace.directory.manifest(payload, progress: progress)
            try workspace.validateManifest(manifest, root: payload)
            self.manifest = manifest
        } catch {
            do { try workspace.removeScratch() } catch let cleanup {
                throw NSError(domain: "Detours.RarCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(error.localizedDescription) The private extraction folder could not be removed: \(cleanup.localizedDescription)"])
            }
            throw error
        }
    }

    func validate(progress: @escaping @Sendable (UInt64) throws -> Void) throws {
        try volumes.validate(progress: progress)
        let current = try workspace.directory.manifest(payload, progress: progress)
        guard current == manifest else { throw OperationFilesystemError.identityChanged }
        try workspace.validateManifest(current, root: payload)
    }

    private static func finish(_ plan: RarExtractionPlan, workspace: OperationWorkspace,
                               progress: @escaping @Sendable (UInt64) throws -> Void) throws {
        for member in plan.members where !member.directory && member.hardLink == nil {
            try progress(0)
            guard let name = plan.paths[member.index], let output = plan.outputs[member.index] else {
                throw SevenZipArchiveError.invalidEntry
            }
            try workspace.synchronizeFile(named: output)
            if member.symbolicLink != nil || member.mode & 0o170000 == 0o120000 {
                let observed = try workspace.directory.observe(output)
                guard observed.byteCount <= 4096 else { throw SevenZipArchiveError.invalidEntry }
                let handle = try workspace.directory.openObservedFile(output, expected: observed)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 4097) ?? Data()
                guard let target = member.symbolicLink ?? String(data: bytes, encoding: .utf8),
                      member.symbolicLink == nil || bytes.isEmpty || bytes == Data(target.utf8) else {
                    throw SevenZipArchiveError.invalidEntry
                }
                try RarExtractionPlan.validateLink(target, at: name)
                try workspace.createSymbolicLink(named: name, target: Data(target.utf8))
            }
        }
        var pending = plan.hardLinks
        while !pending.isEmpty {
            let ready = pending.filter { pending[$0.value] == nil }
            guard !ready.isEmpty else { throw SevenZipArchiveError.invalidEntry }
            for (index, source) in ready {
                try progress(0)
                guard let target = plan.paths[index], let origin = plan.paths[source] else { throw SevenZipArchiveError.invalidEntry }
                try workspace.createHardLink(named: target, to: origin)
                pending.removeValue(forKey: index)
            }
        }
        let explicit = Set(plan.members.filter(\.directory).compactMap { plan.paths[$0.index] })
        for name in plan.directories.reversed() where !explicit.contains(name) {
            try workspace.applyMetadata(named: name, mode: 0o755, modified: nil)
        }
        for member in plan.members.reversed() {
            try progress(0)
            guard let name = plan.paths[member.index] else { throw SevenZipArchiveError.invalidEntry }
            let mode = member.mode == 0 ? UInt32(member.directory ? 0o755 : 0o644) : member.mode & 0o777
            try workspace.applyMetadata(named: name, mode: mode, modified: member.modified)
        }
    }
}
