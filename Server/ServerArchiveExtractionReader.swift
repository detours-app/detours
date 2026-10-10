import DetoursProcess
import Foundation
import RemoteOperationSupport

struct ServerArchiveExtractionReader: Sendable {
    let service: ServerOperationService
    let identity: OperationRequestIdentity
    let ownership: OperationJournal.Ownership
    let input: OperationEffect
    let format: SevenZipArchiveReader.Format
    let password: String?

    func read(measuredBefore: UInt64, output: (@Sendable (SevenZipArchiveReader.Member) throws -> FileHandle)? = nil)
        async throws -> (members: [SevenZipArchiveReader.Member], measured: UInt64) {
        let resolved = try service.resolve(input.location)
        let handle = try resolved.directory.openObservedFile(resolved.name, expected: input.observation)
        defer { try? handle.close() }
        let progress = ServerArchiveProgress(service: service, identity: identity, ownership: ownership, measuredBefore: measuredBefore)
        let members = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SevenZipArchiveReader.Member], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try SevenZipArchiveReader.read(input: handle, format: format, password: password,
                                                               output: output, progress: { try progress.report($0) })
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
        guard try resolved.directory.observe(resolved.name).version == input.observation.version else {
            throw OperationFilesystemError.identityChanged
        }
        return (members, progress.measured)
    }

    func decompressTar(into preparation: ServerPayloadPreparation, measuredBefore: UInt64)
        async throws -> (reader: Self, manifest: OperationManifest, measured: UInt64) {
        let listed = try await read(measuredBefore: measuredBefore)
        guard listed.members.count == 1, let member = listed.members.first, !member.directory,
              member.symbolicLink == nil, member.hardLink == nil else { throw SevenZipArchiveError.invalidEntry }
        let name = Data("archive.tar".utf8)
        try await service.createArchiveOutput(preparation, name: name, identity: identity, ownership: ownership).close()
        let extracted = try await read(measuredBefore: listed.measured, output: { current in
            guard current == member else { throw OperationFilesystemError.identityChanged }
            return try preparation.workspace.openEmptyFileForWriting(named: name)
        })
        guard extracted.members == listed.members else { throw OperationFilesystemError.identityChanged }
        let location = OperationLocation(account: service.journal.account, path: .unix(try preparation.workspace.directory.childPath(name)))
        let manifest = try await service.treeCopyManifest(location, identity: identity, ownership: ownership, measuredBefore: extracted.measured)
        guard let observed = manifest.entries.first?.observation, observed.kind == .file else { throw OperationFilesystemError.identityChanged }
        try preparation.workspace.validateManifest(manifest, root: name)
        let reader = Self(service: service, identity: identity, ownership: ownership,
                          input: .init(location: location, observation: observed), format: .tar, password: nil)
        return (reader, manifest, try service.extractionMeasured(extracted.measured, adding: manifest.proof.byteCount))
    }
}
