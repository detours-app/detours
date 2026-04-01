import Foundation

enum FileOperation {
    case copy(sources: [URL], destination: URL)
    case move(sources: [URL], destination: URL)
    case delete(items: [URL])
    case deleteImmediately(items: [URL])
    case rename(item: URL, newName: String)
    case duplicate(items: [URL])
    case createFolder(directory: URL, name: String)
    case createFile(directory: URL, name: String)
    case archive(items: [URL], format: ArchiveFormat)
    case extract(archive: URL, format: ArchiveFormat)

    /// Present-participle verb for status bar progress text (e.g. "Copying", "Moving")
    var verb: String {
        switch self {
        case .copy: return "Copying"
        case .move: return "Moving"
        case .delete: return "Trashing"
        case .deleteImmediately: return "Deleting"
        case .rename: return "Renaming"
        case .duplicate: return "Duplicating"
        case .createFolder: return "Creating"
        case .createFile: return "Creating"
        case .archive: return "Archiving"
        case .extract: return "Extracting"
        }
    }

    /// Number of source items in the operation
    var itemCount: Int {
        switch self {
        case let .copy(sources, _): return sources.count
        case let .move(sources, _): return sources.count
        case let .delete(items): return items.count
        case let .deleteImmediately(items): return items.count
        case .rename: return 1
        case let .duplicate(items): return items.count
        case .createFolder: return 1
        case .createFile: return 1
        case let .archive(items, _): return items.count
        case .extract: return 1
        }
    }

    var description: String {
        switch self {
        case let .copy(sources, _):
            return sources.count == 1
                ? "Copying \"\(sources[0].lastPathComponent)\"..."
                : "Copying \(sources.count) items..."
        case let .move(sources, _):
            return sources.count == 1
                ? "Moving \"\(sources[0].lastPathComponent)\"..."
                : "Moving \(sources.count) items..."
        case let .delete(items):
            return items.count == 1
                ? "Moving \"\(items[0].lastPathComponent)\" to Trash..."
                : "Moving \(items.count) items to Trash..."
        case let .deleteImmediately(items):
            return items.count == 1
                ? "Deleting \"\(items[0].lastPathComponent)\" permanently..."
                : "Deleting \(items.count) items permanently..."
        case let .rename(item, newName):
            return "Renaming \"\(item.lastPathComponent)\" to \"\(newName)\"..."
        case let .duplicate(items):
            return items.count == 1
                ? "Duplicating \"\(items[0].lastPathComponent)\"..."
                : "Duplicating \(items.count) items..."
        case .createFolder:
            return "Creating folder..."
        case .createFile:
            return "Creating file..."
        case let .archive(items, format):
            return "Creating \(format.displayName) archive with \(items.count) item\(items.count == 1 ? "" : "s")..."
        case let .extract(archive, format):
            return "Extracting \(format.displayName) archive \"\(archive.lastPathComponent)\"..."
        }
    }
}
