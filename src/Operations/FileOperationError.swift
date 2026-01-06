import Foundation

enum FileOperationError: Error {
    case destinationExists(URL)
    case sourceNotFound(URL)
    case permissionDenied(URL)
    case diskFull
    case cancelled
    case partialFailure(succeeded: [URL], failed: [(URL, Error)])
    case unknown(Error)
}

extension FileOperationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .destinationExists(url):
            return "An item named \"\(url.lastPathComponent)\" already exists."
        case let .sourceNotFound(url):
            return "The item \"\(url.lastPathComponent)\" could not be found."
        case let .permissionDenied(url):
            return "Permission denied for \"\(url.lastPathComponent)\"."
        case .diskFull:
            return "The disk is full."
        case .cancelled:
            return "The operation was cancelled."
        case let .partialFailure(_, failed):
            return "\(failed.count) item\(failed.count == 1 ? "" : "s") failed."
        case let .unknown(error):
            return error.localizedDescription
        }
    }
}
