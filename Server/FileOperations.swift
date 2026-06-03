import Foundation

struct FileOperations {
    private let trashOperations: TrashOperations
    private let archiveOperations: ArchiveOperations

    init(
        trashOperations: TrashOperations = TrashOperations(),
        archiveOperations: ArchiveOperations = ArchiveOperations()
    ) {
        self.trashOperations = trashOperations
        self.archiveOperations = archiveOperations
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

    func archiveCreate(items: [String], format: String, archiveName: String, password: String?) throws -> String {
        try archiveOperations.createArchive(
            items: items,
            format: format,
            archiveName: archiveName,
            password: password
        )
    }

    func archiveExtract(archive: String, password: String?) throws -> String {
        try archiveOperations.extractArchive(archive: archive, password: password)
    }
}
