import Foundation

enum TrashOperationsError: Error, Equatable, Sendable {
    case missingItem(String)
    case invalidTrashInfo(String)
    case invalidTrashLocation(String)
    case restoreDestinationOutsideHome(String)
    case restoreDestinationExists(String)
}

struct TrashOperations {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(fileManager: FileManager = .default, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    func trash(paths: [String]) throws -> [String] {
        try ensureTrashDirectories()

        return try paths.map { path in
            let sourceURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw TrashOperationsError.missingItem(path)
            }

            let trashName = uniqueTrashName(for: sourceURL.lastPathComponent)
            let trashedFileURL = filesDirectory.appendingPathComponent(trashName)
            let trashInfoURL = infoDirectory.appendingPathComponent("\(trashName).trashinfo")
            let trashInfo = Self.trashInfoContents(originalPath: sourceURL.path)

            try trashInfo.write(to: trashInfoURL, atomically: true, encoding: .utf8)
            try setPermissions(0o600, at: trashInfoURL)

            do {
                try fileManager.moveItem(at: sourceURL, to: trashedFileURL)
            } catch {
                try? fileManager.removeItem(at: trashInfoURL)
                throw error
            }

            return trashInfoURL.path
        }
    }

    func restore(trashInfoPaths: [String]) throws -> [String] {
        try ensureTrashDirectories()

        return try trashInfoPaths.map { trashInfoPath in
            let trashInfoURL = URL(fileURLWithPath: trashInfoPath).standardizedFileURL.resolvingSymlinksInPath()
            guard isDescendantOrSame(trashInfoURL, of: infoDirectory) else {
                throw TrashOperationsError.invalidTrashLocation(trashInfoPath)
            }

            let originalPath = try originalPath(fromTrashInfo: trashInfoURL)
            let destinationURL = try canonicalRestoreDestination(for: originalPath)
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                throw TrashOperationsError.restoreDestinationExists(destinationURL.path)
            }

            let trashName = trashInfoURL.deletingPathExtension().lastPathComponent
            let trashedFileURL = filesDirectory.appendingPathComponent(trashName)
            guard fileManager.fileExists(atPath: trashedFileURL.path) else {
                throw TrashOperationsError.missingItem(trashedFileURL.path)
            }

            try fileManager.moveItem(at: trashedFileURL, to: destinationURL)
            try fileManager.removeItem(at: trashInfoURL)
            return destinationURL.path
        }
    }

    private var trashDirectory: URL {
        homeDirectory
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("Trash")
    }

    private var filesDirectory: URL {
        trashDirectory.appendingPathComponent("files")
    }

    private var infoDirectory: URL {
        trashDirectory.appendingPathComponent("info")
    }

    private func ensureTrashDirectories() throws {
        for directory in [trashDirectory, filesDirectory, infoDirectory] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try setPermissions(0o700, at: directory)
        }
    }

    private func setPermissions(_ permissions: Int16, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    private func uniqueTrashName(for originalName: String) -> String {
        let baseName = originalName.isEmpty ? "item" : originalName
        while true {
            let candidate = "\(baseName).\(UUID().uuidString.lowercased())"
            let fileURL = filesDirectory.appendingPathComponent(candidate)
            let infoURL = infoDirectory.appendingPathComponent("\(candidate).trashinfo")
            if !fileManager.fileExists(atPath: fileURL.path),
               !fileManager.fileExists(atPath: infoURL.path) {
                return candidate
            }
        }
    }

    private func originalPath(fromTrashInfo url: URL) throws -> String {
        let contents = try String(contentsOf: url, encoding: .utf8)
        for line in contents.components(separatedBy: .newlines) where line.hasPrefix("Path=") {
            let encodedPath = String(line.dropFirst("Path=".count))
            return encodedPath.removingPercentEncoding ?? encodedPath
        }
        throw TrashOperationsError.invalidTrashInfo(url.path)
    }

    private func canonicalRestoreDestination(for originalPath: String) throws -> URL {
        let requestedURL = URL(fileURLWithPath: originalPath).standardizedFileURL
        let parentURL = requestedURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = parentURL.appendingPathComponent(requestedURL.lastPathComponent)

        guard isDescendantOrSame(destinationURL, of: homeDirectory) else {
            throw TrashOperationsError.restoreDestinationOutsideHome(destinationURL.path)
        }

        return destinationURL
    }

    private func isDescendantOrSame(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private static func trashInfoContents(originalPath: String, deletedAt date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let encodedPath = originalPath.addingPercentEncoding(withAllowedCharacters: trashInfoPathAllowed) ?? originalPath
        return """
        [Trash Info]
        Path=\(encodedPath)
        DeletionDate=\(formatter.string(from: date))

        """
    }

    private static let trashInfoPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "\n\r")
        return allowed
    }()
}
