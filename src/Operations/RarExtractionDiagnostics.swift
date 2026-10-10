import DetoursProcess
import Foundation
import RemoteOperationSupport

enum RarExtractionDiagnostics {
    static let ambiguousPassword = "The password may be incorrect, or the encrypted RAR data may be damaged. Check the password and archive, then try extracting again."

    static func map(_ error: Error) -> Error {
        if let failure = error as? SevenZipArchiveError {
            switch failure {
            case .passwordRequired, .wrongPassword: return FileOperationError.archivePasswordRequired
            case .passwordOrCorruption: return FileOperationError.archiveExtractionFailed(ambiguousPassword)
            case .missingVolume(let name): return missing(name)
            case .volumeLimitExceeded: return FileOperationError.archiveExtractionFailed("This RAR archive exceeds the limit of 1,024 parts.")
            case .ambiguousVolumes(let name):
                return FileOperationError.archiveExtractionFailed("More than one RAR part matches \"\(name)\". Keep one complete set in the same folder.")
            case .inconsistentVolumes:
                return FileOperationError.archiveExtractionFailed("These RAR parts do not form one complete archive. Keep every part from the same set in one folder.")
            case .unsupportedMethod: return FileOperationError.archiveExtractionFailed("This RAR compression method is not supported.")
            case .corruptArchive: return FileOperationError.archiveExtractionFailed("The RAR archive is damaged or incomplete. Obtain a complete copy and try again.")
            case .invalidEntry: return FileOperationError.archiveExtractionFailed("The RAR archive contains an unsafe or unsupported file, path or link.")
            case .allocationFailed: return FileOperationError.archiveExtractionFailed("There is not enough memory to extract this RAR archive.")
            case .inputFailure, .nativeFailure: return FileOperationError.archiveExtractionFailed("The RAR archive could not be read or verified.")
            }
        }
        if error as? OperationFilesystemError == .identityChanged {
            return FileOperationError.archiveExtractionFailed("A RAR part or destination changed during extraction. Try again with an unchanged, complete set.")
        }
        if let posix = error as? POSIXError, posix.code == .ENOSPC {
            return FileOperationError.archiveExtractionFailed("There is not enough free space to extract this RAR archive.")
        }
        if error is CancellationError || error as? OperationContractError == .cancelled { return FileOperationError.cancelled }
        if case PowerShellChannelError.remoteError(let message) = error { return remote(message) }
        if case RemoteFileProviderError.invalidResponse(let message) = error { return remote(message) }
        if case OperationCompatibilityError.missingCapabilities(let missing) = error, missing.contains(.rarExtraction) {
            return FileOperationError.archiveExtractionFailed("This remote connection does not support verified RAR extraction. Reconnect with the current Detours helper.")
        }
        return error
    }

    static func remote(_ message: String) -> Error {
        switch message {
        case "passwordRequired", "wrongPassword", "RAR_PASSWORD_REQUIRED", "RAR_PASSWORD_INCORRECT":
            return FileOperationError.archivePasswordRequired
        case "passwordOrCorruption", "RAR_PASSWORD_OR_DAMAGE":
            return FileOperationError.archiveExtractionFailed(ambiguousPassword)
        case "volumeLimitExceeded": return map(SevenZipArchiveError.volumeLimitExceeded)
        case "unsupportedMethod": return map(SevenZipArchiveError.unsupportedMethod)
        case "corruptArchive": return map(SevenZipArchiveError.corruptArchive)
        case "invalidEntry": return map(SevenZipArchiveError.invalidEntry)
        case "identityChanged", "Operation object changed.", "RAR part changed.": return map(OperationFilesystemError.identityChanged)
        case "cancelled", "Operation cancelled.", "Archive operation cancelled.": return FileOperationError.cancelled
        default:
            if message.hasPrefix("missingVolume(") {
                let quoted = message.split(separator: "\"")
                return missing(quoted.count > 1 ? String(quoted[1]) : nil)
            }
            if message.hasPrefix("ambiguousVolumes(") || message.hasPrefix("inconsistentVolumes(") {
                return map(SevenZipArchiveError.inconsistentVolumes(""))
            }
            return FileOperationError.archiveExtractionFailed(message)
        }
    }

    private static func missing(_ name: String?) -> Error {
        let detail = name.map { "The RAR part \"\($0)\" is missing." } ?? "A required RAR part is missing."
        return FileOperationError.archiveExtractionFailed(detail + " Put every part in the same folder, then try again.")
    }
}
