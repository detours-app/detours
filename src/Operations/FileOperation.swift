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

    var description: String {
        switch self {
        case let .copy(sources, _):
            return "Copying \(sources.count) item\(sources.count == 1 ? "" : "s")..."
        case let .move(sources, _):
            return "Moving \(sources.count) item\(sources.count == 1 ? "" : "s")..."
        case let .delete(items):
            return "Moving \(items.count) item\(items.count == 1 ? "" : "s") to Trash..."
        case let .deleteImmediately(items):
            return "Deleting \(items.count) item\(items.count == 1 ? "" : "s") permanently..."
        case .rename:
            return "Renaming item..."
        case let .duplicate(items):
            return "Duplicating \(items.count) item\(items.count == 1 ? "" : "s")..."
        case .createFolder:
            return "Creating folder..."
        case .createFile:
            return "Creating file..."
        }
    }
}
