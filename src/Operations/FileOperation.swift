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
