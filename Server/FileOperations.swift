import Foundation

struct FileOperations {
    private let trashOperations: TrashOperations

    init(trashOperations: TrashOperations = TrashOperations()) {
        self.trashOperations = trashOperations
    }

    func listPlaceholder() throws -> String {
        "[]"
    }

    func trash(paths: [String]) throws -> [String] {
        try trashOperations.trash(paths: paths)
    }

    func restoreFromTrash(trashInfoPaths: [String]) throws -> [String] {
        try trashOperations.restore(trashInfoPaths: trashInfoPaths)
    }
}
