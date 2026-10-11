import Foundation

extension OperationIntent {
    public func validateRarSources() throws {
        guard action == .archiveExtract, archiveFormat == "rar" else { return }
        guard !sources.isEmpty, sources.count <= 1_024, sources.count == sourceObservations.count,
              Set(sources).count == sources.count,
              Set(sourceObservations.map(\.identity)).count == sources.count,
              sourceObservations.allSatisfy({ $0.kind == .file && $0.sha256 != nil }),
              let first = sources.first, sources.allSatisfy({ $0.account == first.account }),
              destination?.account == first.account else { throw OperationContractError.invalidReceipt }
        let parent = try OperationPublication.split(first).parent
        guard try sources.allSatisfy({ try OperationPublication.split($0).parent == parent }) else {
            throw OperationContractError.invalidReceipt
        }
    }

    public func proveRarSources(progress: (UInt64) throws -> Void) throws {
        guard action == .archiveExtract, archiveFormat == "rar" else { return }
        try validateRarSources()
        for (source, expected) in zip(sources, sourceObservations) {
            let path = try OperationPublication.split(source)
            let directory = try OperationDirectory(path: path.parent)
            guard try directory.proveFile(path.name, progress: progress) == expected else {
                throw OperationFilesystemError.identityChanged
            }
            try directory.requireCurrentPath()
        }
    }
}
