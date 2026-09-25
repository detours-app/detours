import DetoursProcess
import Foundation
import RemoteOperationSupport

struct ServerArchiveSources: Sendable {
    let root: OperationLocation
    let manifest: OperationManifest
    let inputs: OperationManifest
    let locations: [Data: Data]
    let measuredBytes: UInt64
}

extension ServerOperationService {
    func archiveSources(_ intent: OperationIntent, identity: OperationRequestIdentity,
                        ownership: OperationJournal.Ownership, measuredBefore: UInt64) async throws -> ServerArchiveSources {
        guard !intent.sources.isEmpty, intent.sources.count == intent.sourceObservations.count else {
            throw OperationContractError.invalidReceipt
        }
        let paths: [[Data]] = try intent.sources.map { source in
            guard source.account == journal.account, case .unix(let path) = source.path, path.first == 47 else {
                throw OperationFilesystemError.invalidPath
            }
            let components = path.dropFirst().split(separator: 47, omittingEmptySubsequences: false).map { Data($0) }
            guard !components.isEmpty else { throw OperationFilesystemError.invalidPath }
            for component in components {
                guard !component.isEmpty, component != Data(".".utf8), component != Data("..".utf8),
                      !component.contains(0), String(data: component, encoding: .utf8) != nil else {
                    throw OperationFilesystemError.invalidPath
                }
            }
            return components
        }
        var common = Array(paths[0].dropLast())
        for path in paths {
            while !path.dropLast().starts(with: common) { common.removeLast() }
        }
        let root = OperationLocation(account: journal.account, path: .unix(Data([47]) + Data(common.joined(separator: Data([47])))))
        var trees: [(prefix: Data, manifest: OperationManifest)] = []
        var measured = measuredBefore
        for (index, source) in intent.sources.enumerated() {
            let manifest = try await treeCopyManifest(source, identity: identity, ownership: ownership, measuredBefore: measured)
            guard let observed = manifest.entries.first?.observation else { throw OperationContractError.invalidReceipt }
            let expected = intent.sourceObservations[index]
            let hash = observed.kind == .file ? observed.sha256 : manifest.proof.sha256
            guard observed.identity == expected.identity, observed.version == expected.version, observed.kind == expected.kind,
                  observed.linkTarget == expected.linkTarget, expected.sha256 == nil || expected.sha256 == hash else {
                throw OperationFilesystemError.identityChanged
            }
            let (next, overflow) = measured.addingReportingOverflow(manifest.proof.byteCount)
            guard !overflow else { throw OperationFilesystemError.unsupported }
            measured = next
            trees.append((Data(paths[index].dropFirst(common.count).joined(separator: Data([47]))), manifest))
        }
        var inputTrees: [(prefix: Data, manifest: OperationManifest)] = []
        var locations: [Data: Data] = [:]
        let followingLinks = intent.archiveFormat == ServerArchiveFormat.sevenZ.rawValue || intent.archiveFormat == ServerArchiveFormat.zip.rawValue
        for (index, source) in intent.sources.enumerated() {
            let input = try await archiveInputManifest(source, followingLinks: followingLinks, identity: identity,
                                                       ownership: ownership, measuredBefore: measured)
            let prefix: Data
            if intent.archiveFormat == ServerArchiveFormat.sevenZ.rawValue {
                guard let name = paths[index].last else { throw OperationFilesystemError.invalidPath }
                prefix = name
            } else { prefix = trees[index].prefix }
            inputTrees.append((prefix, input.manifest))
            for (relative, physical) in input.locations {
                let name = relative.isEmpty ? prefix : prefix + Data([47]) + relative
                locations[name] = physical
            }
            let (next, overflow) = measured.addingReportingOverflow(input.manifest.proof.byteCount)
            guard !overflow else { throw OperationFilesystemError.unsupported }
            measured = next
        }
        return ServerArchiveSources(root: root, manifest: try OperationManifest.combining(trees),
                                    inputs: try OperationManifest.combining(inputTrees), locations: locations,
                                    measuredBytes: measured - measuredBefore)
    }

    func archiveEntries(_ sources: ServerArchiveSources, id: OperationItemID) throws -> [SevenZipArchiveWriter.Entry] {
        try sources.inputs.entries.map { entry in
            let observation = entry.observation
            guard let name = String(data: entry.relativePath, encoding: .utf8),
                  let metadata = observation.contentVersion.flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw OperationFilesystemError.unsupported
            }
            let fields = metadata.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 6, let seconds = Int64(fields[1]), let nanos = UInt32(fields[2]), nanos < 1_000_000_000,
                  let mode = UInt32(fields[3]) else { throw OperationFilesystemError.unsupported }
            guard let path = sources.locations[entry.relativePath] else { throw OperationFilesystemError.invalidPath }
            let location = OperationLocation(account: journal.account, path: .unix(path))
            let opener: (@Sendable () throws -> FileHandle)?
            if observation.kind == .file {
                opener = {
                    guard try !self.journal.cancellationRequested(id) else { throw OperationContractError.cancelled }
                    let source = try self.resolve(location)
                    return try source.directory.openObservedFile(source.name, expected: observation)
                }
            } else { opener = nil }
            return SevenZipArchiveWriter.Entry(
                name: name, input: nil, size: observation.kind == .file ? observation.byteCount : 0,
                directory: observation.kind == .directory, mode: mode,
                modified: Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000),
                linkTarget: observation.linkTarget, openInput: opener
            )
        }
    }

    private func archiveInputManifest(_ location: OperationLocation, followingLinks: Bool, identity: OperationRequestIdentity,
                                      ownership: OperationJournal.Ownership, measuredBefore: UInt64) async throws -> OperationArchiveInputs {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let source = try self.resolve(location)
                    let clock = ContinuousClock()
                    var reported = clock.now
                    let inputs = try source.directory.archiveInputs(source.name, followingLinks: followingLinks) { bytes in
                        guard try !self.journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
                        if clock.now - reported >= .seconds(5) {
                            let (total, overflow) = measuredBefore.addingReportingOverflow(bytes)
                            guard !overflow else { throw OperationFilesystemError.unsupported }
                            try self.recordTreeProgress(identity, measured: total, ownership: ownership)
                            reported = clock.now
                        }
                    }
                    continuation.resume(returning: inputs)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
