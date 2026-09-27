import Foundation

/// A remote file-operation failure carrying enough context to tell the user what failed, on
/// which item and host, why, and what to do next, so a remote error never degrades into a bare
/// "Operation Failed" box. The underlying error supplies the reason and recovery suggestion.
struct RemoteOperationError: LocalizedError {
    enum Action {
        case copy, move, delete, restore, rename, createFolder

        var verb: String {
            switch self {
            case .copy: return "copy"
            case .move: return "move"
            case .delete: return "delete"
            case .restore: return "restore"
            case .rename: return "rename"
            case .createFolder: return "create"
            }
        }
    }

    let summary: String
    let underlying: Error

    var errorDescription: String? { summary }
    var failureReason: String? { Self.reason(for: underlying) }
    var recoverySuggestion: String? { Self.suggestion(for: underlying) }

    /// Failure of a concrete action on a named item and host.
    static func operation(action: Action, item: String, host: String, underlying: Error) -> RemoteOperationError {
        RemoteOperationError(
            summary: "Couldn't \(action.verb) \"\(item)\" on \(host).",
            underlying: underlying
        )
    }

    /// Failure while undoing the last remote change on a host.
    static func undo(host: String, underlying: Error) -> RemoteOperationError {
        RemoteOperationError(
            summary: "Couldn't undo the last change on \(host).",
            underlying: underlying
        )
    }

    /// The human-readable reason, taken from the underlying error's own description plus any
    /// extra detail it carries (e.g. the host's own message for a remote error).
    static func reason(for error: Error) -> String {
        guard let localized = error as? LocalizedError, let primary = localized.errorDescription else {
            return error.localizedDescription
        }
        if let detail = localized.failureReason, !detail.isEmpty, detail != primary {
            return "\(primary) \(detail)"
        }
        return primary
    }

    /// A transport failure cannot establish whether a file change completed.
    static func suggestion(for error: Error) -> String {
        return "Open operation details and check the result before making another change."
    }
}
