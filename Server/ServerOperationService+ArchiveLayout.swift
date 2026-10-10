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
}
