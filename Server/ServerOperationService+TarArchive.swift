import DetoursProcess
import Foundation
import RemoteOperationSupport

struct ServerTarArchive: Sendable {
    let entry: SevenZipArchiveWriter.Entry
    let location: OperationLocation
    let manifest: OperationManifest
    let measuredBytes: UInt64
}

extension ServerOperationService {
    func prepareTar(_ entries: [SevenZipArchiveWriter.Entry], preparation: ServerPayloadPreparation,
                    identity: OperationRequestIdentity, ownership: OperationJournal.Ownership,
                    measuredBefore: UInt64) async throws -> ServerTarArchive {
        let name = Data("archive.tar".utf8)
        let output = try await createArchiveOutput(preparation, name: name, identity: identity, ownership: ownership)
        let progress = ServerArchiveProgress(service: self, identity: identity, ownership: ownership, measuredBefore: measuredBefore)
        do {
            try await writeArchive(entries, output: output, password: nil, format: .tar, progress: progress)
            try output.close()
        } catch {
            try output.close()
            throw error
        }
        let location = OperationLocation(account: journal.account, path: .unix(try preparation.workspace.directory.childPath(name)))
        let manifest = try await treeCopyManifest(location, identity: identity, ownership: ownership, measuredBefore: progress.measured)
        guard let observed = manifest.entries.first?.observation, observed.kind == .file else { throw OperationContractError.invalidReceipt }
        try preparation.workspace.validateManifest(manifest, root: name)
        let (measured, overflow) = progress.measured.addingReportingOverflow(manifest.proof.byteCount)
        guard !overflow else { throw OperationFilesystemError.unsupported }
        let entry = SevenZipArchiveWriter.Entry(name: "archive.tar", input: nil, size: observed.byteCount,
                                                directory: false, mode: 0o100600, modified: Date(timeIntervalSince1970: 0), openInput: {
            guard try !self.journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
            let input = try self.resolve(location)
            return try input.directory.openObservedFile(input.name, expected: observed)
        })
        return ServerTarArchive(entry: entry, location: location, manifest: manifest, measuredBytes: measured)
    }
}
