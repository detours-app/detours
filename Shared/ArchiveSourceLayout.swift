import Foundation

public struct ArchiveSourceLayout: Sendable {
    public let workingDirectory: URL
    public let relativePaths: [String]

    public init(items: [URL]) {
        precondition(!items.isEmpty)
        let standardizedItems = items.map(\.standardizedFileURL)
        var root = standardizedItems[0].deletingLastPathComponent()

        while !standardizedItems.allSatisfy({ Self.contains($0, in: root) }), root.path != "/" {
            root.deleteLastPathComponent()
        }

        workingDirectory = root
        let prefix = root.path == "/" ? "/" : root.path + "/"
        relativePaths = standardizedItems.map { item in
            String(item.path.dropFirst(prefix.count))
        }
    }

    private static func contains(_ item: URL, in directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path
        if directoryPath == "/" {
            return itemPath.hasPrefix("/")
        }
        return itemPath == directoryPath || itemPath.hasPrefix(directoryPath + "/")
    }
}
