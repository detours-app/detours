import Foundation
@testable import Detours

/// An in-memory host with files, folders and links, for the cross-host link tests. Links are
/// stored as their raw text and resolved one hop at a time, like the real providers.
actor SymlinkFakeProvider: FileProvider {
    enum Node: Equatable {
        case file(Data)
        case directory
        case link(String)

        var isLink: Bool {
            if case .link = self { return true }
            return false
        }
    }

    enum Failure: Error, Equatable {
        case missing(String)
        case notAFile(String)
        case exists(String)
    }

    let hostID: UUID
    private var nodes: [String: Node]
    /// Every state-changing call in order: "mkdir /p", "upload /p", "symlink /p -> t", "trash /p".
    private(set) var calls: [String] = []

    init(hostID: UUID, nodes: [String: Node]) {
        self.hostID = hostID
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { (Self.canonical($0.key), $0.value) })
    }

    static func canonical(_ path: String) -> String {
        SymlinkTransferWalker.canonicalPath(SymlinkTransferWalker.canonicalComponents(of: path))
    }

    func node(at path: String) -> Node? { nodes[Self.canonical(path)] }

    func paths() -> [String] { nodes.keys.sorted() }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        let directory = Self.canonical(location.path)
        guard nodes[directory] == .directory else { throw Failure.missing(directory) }
        let prefix = directory == "/" ? "/" : directory + "/"
        return nodes.keys
            .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .sorted()
            .map { entry(at: $0) }
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        let path = Self.canonical(location.path)
        guard nodes[path] != nil else { throw Failure.missing(path) }
        return entry(at: path)
    }

    private func entry(at path: String) -> LoadedFileEntry {
        let node = nodes[path]
        var size: Int64?
        if case .file(let data) = node { size = Int64(data.count) }
        return LoadedFileEntry(
            location: .remote(hostID: hostID, path: path),
            url: Location.remoteFileURL(path),
            name: String(path.split(separator: "/").last ?? ""),
            isDirectory: node == .directory,
            isSymbolicLink: node?.isLink ?? false,
            fileSize: size
        )
    }

    func readSymlink(_ location: Location) async throws -> Location {
        let path = Self.canonical(location.path)
        guard case .link(let target)? = nodes[path] else { throw Failure.missing(path) }
        if target.hasPrefix("/") {
            return .remote(hostID: hostID, path: target)
        }
        let parent = location.deletingLastPathComponent().path
        return .remote(hostID: hostID, path: (parent == "/" ? "" : parent) + "/" + target)
    }

    func download(_ location: Location, to localURL: URL) async throws {
        let path = Self.canonical(location.path)
        guard case .file(let data)? = nodes[path] else { throw Failure.notAFile(path) }
        try data.write(to: localURL)
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        let path = Self.canonical(location.path)
        nodes[path] = .file(try Data(contentsOf: localURL))
        calls.append("upload \(path)")
    }

    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {
        let path = Self.canonical(location.path)
        if withIntermediateDirectories {
            var current = ""
            for component in SymlinkTransferWalker.canonicalComponents(of: path) {
                current += "/" + component
                if nodes[current] == nil { nodes[current] = .directory }
            }
        } else {
            nodes[path] = .directory
        }
        calls.append("mkdir \(path)")
    }

    func createSymbolicLink(at location: Location, targetPath: String) async throws {
        let path = Self.canonical(location.path)
        guard nodes[path] == nil else { throw Failure.exists(path) }
        nodes[path] = .link(targetPath)
        calls.append("symlink \(path) -> \(targetPath)")
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        try items.map { item in
            let path = Self.canonical(item.path)
            guard nodes[path] != nil else { throw Failure.missing(path) }
            removeTree(at: path)
            calls.append("trash \(path)")
            return TrashedItem(originalLocation: item, trashLocation: .remote(hostID: hostID, path: "/trash/\(UUID().uuidString)"))
        }
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        items.map(\.originalLocation)
    }

    func delete(_ items: [Location]) async throws {
        for item in items { removeTree(at: Self.canonical(item.path)) }
    }

    private func removeTree(at path: String) {
        let prefix = path + "/"
        for key in nodes.keys where key == path || key.hasPrefix(prefix) {
            nodes.removeValue(forKey: key)
        }
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func rename(_ item: Location, to newName: String) async throws -> Location { item }
    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location { items[0] }
    func archiveExtract(_ archive: Location, password: String?) async throws -> Location { archive }
    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        FileProviderWatch(id: UUID(), location: location)
    }
    func unwatch(_ watch: FileProviderWatch) async {}
    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func openForQuickLook(_ location: Location) async throws -> URL { URL(fileURLWithPath: "/tmp/unused") }
}
