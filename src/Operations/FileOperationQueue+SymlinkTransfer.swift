import Foundation

/// Where a nested link ends up when a folder crosses hosts.
enum SymlinkWalkOutcome: Equatable {
    /// The link points inside the copied tree: recreate it with this relative target.
    case recreate(relativeTarget: String)
    /// The link points outside the copied tree: copy what it points at under the link's name.
    case follow(Location, isDirectory: Bool)
}

/// Paths of the copied tree that decide how a nested link is treated.
struct SymlinkWalkContext {
    /// Canonical components of the copied root on the source host.
    let rootComponents: [String]
    /// The staged local copy of that root.
    let rootStagedURL: URL
    /// Canonical paths of the source directories currently being walked, root first.
    var activeDirectories: [String]
    /// Nested links that could not be transferred, by source path.
    var failures: [(URL, Error)] = []

    init(root: Location, rootStagedURL: URL) {
        let rootPath = SymlinkTransferWalker.canonicalPath(of: root)
        rootComponents = SymlinkTransferWalker.canonicalComponents(of: rootPath)
        self.rootStagedURL = rootStagedURL.standardizedFileURL
        activeDirectories = [rootPath]
    }

    func isActive(_ location: Location) -> Bool {
        activeDirectories.contains(SymlinkTransferWalker.canonicalPath(of: location))
    }

    /// The relative target for a link staged at `stagedLink` whose referent is `target`, or nil
    /// when the referent lies outside the copied root.
    func relativeTarget(forLinkAt stagedLink: URL, pointingAt target: Location) -> String? {
        let targetComponents = SymlinkTransferWalker.canonicalComponents(of: SymlinkTransferWalker.canonicalPath(of: target))
        guard targetComponents.starts(with: rootComponents) else { return nil }
        let targetInsideRoot = Array(targetComponents.dropFirst(rootComponents.count))
        let linkDirectory = stagedLink.standardizedFileURL.deletingLastPathComponent()
        let linkInsideRoot = Array(linkDirectory.pathComponents.dropFirst(rootStagedURL.pathComponents.count))
        let shared = zip(linkInsideRoot, targetInsideRoot).prefix { $0 == $1 }.count
        let ups = Array(repeating: "..", count: linkInsideRoot.count - shared)
        let relative = (ups + targetInsideRoot.dropFirst(shared)).joined(separator: "/")
        return relative.isEmpty ? "." : relative
    }
}

/// Stages one selected item of a Unix-to-Unix cross-host transfer into a local folder,
/// resolving links the way the spec describes: a selected link becomes its final referent, a
/// nested link inside the copied tree stays a link, a nested link outside it is followed.
struct SymlinkTransferWalker {
    let provider: any FileProvider

    /// Kernel-style ceiling on link hops, a second guard beside the visited set.
    static let maximumHops = 40

    /// Follows `link` hop by hop to its final non-link entry. A hop that cannot be read fails
    /// as a missing target; a repeated location or too many hops fails as a loop. Both name
    /// the link the user sees, `name`, not the hop that failed.
    func resolveFinalTarget(of link: Location, name: String) async throws -> (location: Location, entry: LoadedFileEntry) {
        var visited: Set<String> = [Self.canonicalPath(of: link)]
        var current = link
        for _ in 0..<Self.maximumHops {
            let next: Location
            do {
                next = try await provider.readSymlink(current)
            } catch {
                throw FileOperationError.linkTargetMissing(name: name)
            }
            guard visited.insert(Self.canonicalPath(of: next)).inserted else {
                throw FileOperationError.linkLoops(name: name)
            }
            let entry: LoadedFileEntry
            do {
                entry = try await provider.stat(next)
            } catch {
                throw FileOperationError.linkTargetMissing(name: name)
            }
            if !entry.isSymbolicLink {
                return (Self.canonicalLocation(next), entry)
            }
            current = next
        }
        throw FileOperationError.linkLoops(name: name)
    }

    /// Stages `item` at `stagedURL` and returns the nested links that failed. A selected link
    /// that cannot be resolved throws, failing the whole item.
    func stage(_ item: Location, to stagedURL: URL) async throws -> [(URL, Error)] {
        var source = item
        var entry = try await provider.stat(item)
        if entry.isSymbolicLink {
            (source, entry) = try await resolveFinalTarget(of: item, name: item.lastPathComponent)
        }
        guard entry.isDirectory else {
            try FileManager.default.createDirectory(
                at: stagedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await provider.download(source, to: stagedURL)
            return []
        }
        var context = SymlinkWalkContext(root: source, rootStagedURL: stagedURL)
        try await walkDirectory(source, to: stagedURL, context: &context)
        return context.failures
    }

    /// Decides what a nested link becomes. Exposed for the plan tests.
    func classify(link: Location, name: String, stagedLink: URL, context: SymlinkWalkContext) async throws -> SymlinkWalkOutcome {
        let target = try await resolveFinalTarget(of: link, name: name)
        if target.entry.isDirectory, context.isActive(target.location) {
            throw FileOperationError.linkLoops(name: name)
        }
        if let relative = context.relativeTarget(forLinkAt: stagedLink, pointingAt: target.location) {
            return .recreate(relativeTarget: relative)
        }
        return .follow(target.location, isDirectory: target.entry.isDirectory)
    }

    private func walkDirectory(_ directory: Location, to stagedURL: URL, context: inout SymlinkWalkContext) async throws {
        context.activeDirectories.append(Self.canonicalPath(of: directory))
        defer { context.activeDirectories.removeLast() }
        try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: true)
        for child in try await provider.list(directory, showHidden: true) {
            try Task.checkCancellation()
            let childURL = stagedURL.appendingPathComponent(child.name)
            if child.isSymbolicLink {
                try await stageNestedLink(child, at: childURL, context: &context)
            } else if child.isDirectory {
                try await walkDirectory(child.location, to: childURL, context: &context)
            } else {
                try await provider.download(child.location, to: childURL)
            }
        }
    }

    private func stageNestedLink(_ link: LoadedFileEntry, at stagedLink: URL, context: inout SymlinkWalkContext) async throws {
        do {
            switch try await classify(link: link.location, name: link.name, stagedLink: stagedLink, context: context) {
            case .recreate(let relativeTarget):
                try FileManager.default.createSymbolicLink(atPath: stagedLink.path, withDestinationPath: relativeTarget)
            case .follow(let target, isDirectory: true):
                try await walkDirectory(target, to: stagedLink, context: &context)
            case .follow(let target, isDirectory: false):
                try await provider.download(target, to: stagedLink)
            }
        } catch let error as FileOperationError {
            switch error {
            case .linkLoops, .linkTargetMissing:
                // Only the staged remainder of this link goes: it lives in the app's own
                // temporary transfer folder, never in a user directory.
                try? FileManager.default.removeItem(at: stagedLink)
                context.failures.append((URL(fileURLWithPath: link.location.path), error))
            default:
                throw error
            }
        }
    }

    /// Lexical canonicalisation: absolute components with `.` and `..` folded. No file system
    /// access, so a remote path is never handed to the local automounter.
    static func canonicalComponents(of path: String) -> [String] {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        return components
    }

    static func canonicalPath(_ components: [String]) -> String {
        "/" + components.joined(separator: "/")
    }

    /// One spelling per item. Remote paths are folded lexically only. A local path also has
    /// every component but the last resolved on disk, because the Mac spells its temporary
    /// folders both /var and /private/var; the last component stays as written so a link is
    /// still addressed as the link, never as its target.
    static func canonicalPath(of location: Location) -> String {
        let components = canonicalComponents(of: location.path)
        guard case .local = location, let last = components.last else {
            return canonicalPath(components)
        }
        let parent = URL(fileURLWithPath: canonicalPath(Array(components.dropLast())), isDirectory: true)
        return canonicalPath(canonicalComponents(of: parent.resolvingSymlinksInPath().path) + [last])
    }

    static func canonicalLocation(_ location: Location) -> Location {
        let path = canonicalPath(of: location)
        switch location {
        case .local:
            return .local(URL(fileURLWithPath: path))
        case .remote(let hostID, _):
            return .remote(hostID: hostID, path: path)
        }
    }
}

extension FileOperationQueue {
    /// Stages one item for a Unix-to-Unix transfer and returns its failed nested links.
    func stageUnixItem(_ item: Location, provider: any FileProvider, to stagedURL: URL) async throws -> [(URL, Error)] {
        try await SymlinkTransferWalker(provider: provider).stage(item, to: stagedURL)
    }

    /// Uploads a staged item, recreating a staged link through the provider once its
    /// containing folder exists.
    func uploadUnixStagedItem(_ localURL: URL, to location: Location, provider: any FileProvider) async throws {
        let values = try localURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: localURL.path)
            try await provider.createSymbolicLink(at: location, targetPath: target)
            return
        }
        if values.isDirectory == true {
            try await provider.createDirectory(at: location, withIntermediateDirectories: true)
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                try await uploadUnixStagedItem(
                    child,
                    to: location.appendingPathComponent(child.lastPathComponent),
                    provider: provider
                )
            }
            return
        }
        try await provider.upload(localURL, to: location)
    }
}
