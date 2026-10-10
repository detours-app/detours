import DetoursProcess
import Foundation
import RemoteOperationSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension ServerOperationService {
    func archiveLayout(_ location: OperationLocation, format: String, password: String?) throws -> OperationReply {
        try journal.validateEpoch()
        guard location.account == journal.account else { return .incompatible(.accountMismatch) }
        if format == "rar" { return try rarLayout(location, password: password) }
        let codec: SevenZipArchiveReader.Format
        switch format {
        case "zip": codec = .zip
        case "sevenZ": codec = .sevenZ
        case "tarGz": codec = .gzip
        case "tarBz2": codec = .bzip2
        case "tarXz": codec = .xz
        default: return .archiveLayout(.unsupported)
        }
        do {
            let source = try resolve(location)
            let observed = try source.directory.proveFile(source.name, progress: { _ in try Task.checkCancellation() })
            let input = try source.directory.openObservedFile(source.name, expected: observed)
            defer { try? input.close() }
            let name = try ArchiveExtractionLayout.singleRoot(input: input, format: codec, password: password,
                progress: { _ in try Task.checkCancellation() })
            guard try source.directory.proveFile(source.name, progress: { _ in try Task.checkCancellation() }) == observed else {
                throw OperationFilesystemError.identityChanged
            }
            return .archiveLayout(.found(.init(source: observed, singleRoot: name)))
        } catch SevenZipArchiveError.passwordRequired {
            return .archivePasswordRequired
        } catch OperationFilesystemError.system(let code) {
            switch code {
            case ENOENT: return .archiveLayout(.missing)
            case EACCES, EPERM: return .archiveLayout(.denied)
            case ENOTCONN: return .archiveLayout(.disconnected)
            default: throw OperationFilesystemError.system(code)
            }
        } catch OperationFilesystemError.unsupported { return .archiveLayout(.unsupported) }
    }

    private func rarLayout(_ location: OperationLocation, password: String?) throws -> OperationReply {
        do {
            let source = try resolve(location)
            guard let selected = String(data: source.name, encoding: .utf8) else { throw OperationFilesystemError.invalidPath }
            let volumes = try RarVolumeSet.discover(directory: source.directory, selected: selected, password: password,
                                                    progress: { _ in try Task.checkCancellation() })
            guard let first = volumes.parts.first else { throw OperationFilesystemError.invalidPath }
            let locations = try volumes.parts.map {
                OperationLocation(account: location.account, path: .unix(try source.directory.childPath(Data($0.name.utf8))))
            }
            let root = try ArchiveExtractionLayout.singleRoot(members: volumes.members, password: password)
            return .archiveLayout(.found(.init(source: first.observation, singleRoot: root, rarSources: locations,
                rarObservations: volumes.parts.map(\.observation), rarBaseName: volumes.baseName)))
        } catch SevenZipArchiveError.passwordRequired {
            return .archivePasswordRequired
        }
    }
}
