import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct OperationOwnedObject: Codable, Equatable, Sendable {
    public let name: Data
    public let identity: OperationObjectIdentity
    public let kind: OperationObservation.Kind

    init(name: Data, observation: OperationObservation) {
        self.name = name
        self.identity = observation.identity
        self.kind = observation.kind
    }
}

public final class OperationWorkspace {
    public struct Record: Codable, Equatable, Sendable {
        public let id: OperationItemID
        public let root: OperationOwnedObject
        public let objects: [OperationOwnedObject]
    }

    private let parent: OperationDirectory
    public let directory: OperationDirectory
    public private(set) var record: Record

    public static func plannedName(for id: OperationItemID) -> Data {
        Data(".detours-partial-\(id.operation)-\(id.item)-\(UUID())".utf8)
    }

    public init(parent: OperationDirectory, id: OperationItemID, plannedName: Data? = nil) throws {
        let name = plannedName ?? Self.plannedName(for: id)
        try OperationDirectory.validateName(name)
        let result = try OperationDirectory.withBytes(name) { mkdirat(parent.descriptor, $0, mode_t(0o700)) }
        guard result == 0 else { throw OperationDirectory.systemError() }
        try parent.synchronize()
        let observed = try parent.observe(name)
        let directory = try OperationDirectory(path: parent.childPath(name))
        guard observed.identity == directory.identity else { throw OperationFilesystemError.identityChanged }
        self.parent = parent
        self.directory = directory
        self.record = Record(id: id, root: OperationOwnedObject(name: name, observation: observed), objects: [])
    }

    public init(parent: OperationDirectory, record: Record) throws {
        let observation = try parent.observe(record.root.name)
        guard observation.identity == record.root.identity, observation.kind == .directory else {
            throw OperationFilesystemError.identityChanged
        }
        let directory = try OperationDirectory(path: parent.childPath(record.root.name))
        guard directory.identity == record.root.identity else { throw OperationFilesystemError.identityChanged }
        self.parent = parent
        self.directory = directory
        self.record = record
    }

    public func createFile(named name: Data) throws -> FileHandle {
        try requireRoot()
        let target = try parentForObject(name)
        let descriptor = try OperationDirectory.withBytes(target.name) {
            openat(target.directory.descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw OperationDirectory.systemError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw OperationDirectory.systemError() }
        let observation = try target.directory.observe(target.name)
        guard observation.identity == OperationDirectory.identity(info) else { throw OperationFilesystemError.identityChanged }
        record = Record(id: record.id, root: record.root,
                        objects: record.objects + [OperationOwnedObject(name: name, observation: observation)])
        try target.directory.synchronize()
        return handle
    }

    public func synchronizeFile(named name: Data) throws {
        try requireRoot()
        guard let owned = record.objects.first(where: { $0.name == name }), owned.kind == .file else {
            throw OperationFilesystemError.unexpectedContents
        }
        let target = try parentForObject(name)
        let descriptor = try OperationDirectory.withBytes(target.name) {
            openat(target.directory.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw OperationDirectory.systemError() }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw OperationDirectory.systemError() }
        guard OperationDirectory.identity(info) == owned.identity else { throw OperationFilesystemError.identityChanged }
        guard fsync(descriptor) == 0 else { throw OperationDirectory.systemError() }
    }

    public func createDirectory(named name: Data) throws {
        try requireRoot()
        let target = try parentForObject(name)
        let result = try OperationDirectory.withBytes(target.name) {
            mkdirat(target.directory.descriptor, $0, mode_t(0o700))
        }
        guard result == 0 else { throw OperationDirectory.systemError() }
        let observation = try target.directory.observe(target.name)
        guard observation.kind == .directory else { throw OperationFilesystemError.identityChanged }
        record = Record(id: record.id, root: record.root,
                        objects: record.objects + [OperationOwnedObject(name: name, observation: observation)])
        try target.directory.synchronize()
    }

    public func createSymbolicLink(named name: Data, target contents: Data) throws {
        try requireRoot()
        let target = try parentForObject(name)
        let result = try OperationDirectory.withBytes(contents) { contents in
            try OperationDirectory.withBytes(target.name) { symlinkat(contents, target.directory.descriptor, $0) }
        }
        guard result == 0 else { throw OperationDirectory.systemError() }
        let observation = try target.directory.observe(target.name)
        guard observation.kind == .symbolicLink, observation.linkTarget == contents else {
            throw OperationFilesystemError.identityChanged
        }
        record = Record(id: record.id, root: record.root,
                        objects: record.objects + [OperationOwnedObject(name: name, observation: observation)])
        try target.directory.synchronize()
    }

    public func removeScratch() throws {
        try requireRoot()
        var order: [Data] = []
        try inspectOwnedTree(directory, prefix: Data(), order: &order)
        for name in order {
            guard let object = record.objects.first(where: { $0.name == name }) else {
                throw OperationFilesystemError.unexpectedContents
            }
            let target = try parentForObject(name)
            let observation = try target.directory.observe(target.name)
            guard observation.identity == object.identity, observation.kind == object.kind else {
                throw OperationFilesystemError.identityChanged
            }
            var parentInformation = stat()
            guard fstat(target.directory.descriptor, &parentInformation) == 0,
                  fchmod(target.directory.descriptor, (parentInformation.st_mode & ~mode_t(S_IFMT)) | mode_t(0o700)) == 0 else {
                throw OperationDirectory.systemError()
            }
            let flags = object.kind == .directory ? AT_REMOVEDIR : 0
            let result = try OperationDirectory.withBytes(target.name) { unlinkat(target.directory.descriptor, $0, flags) }
            guard result == 0 else { throw OperationDirectory.systemError() }
            try target.directory.synchronize()
        }
        try requireRoot()
        let result = try OperationDirectory.withBytes(record.root.name) { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
        guard result == 0 else { throw OperationDirectory.systemError() }
        try parent.synchronize()
    }

    private func inspectOwnedTree(_ directory: OperationDirectory, prefix: Data, order: inout [Data]) throws {
        try directory.requireCurrentPath()
        for name in try directory.names() {
            let relative = prefix.isEmpty ? name : prefix + Data([47]) + name
            guard let object = record.objects.first(where: { $0.name == relative }) else {
                throw OperationFilesystemError.unexpectedContents
            }
            let observation = try directory.observe(name)
            guard observation.identity == object.identity, observation.kind == object.kind else {
                throw OperationFilesystemError.identityChanged
            }
            if observation.kind == .directory {
                let child = try OperationDirectory(path: directory.childPath(name))
                guard child.identity == object.identity else { throw OperationFilesystemError.identityChanged }
                try inspectOwnedTree(child, prefix: relative, order: &order)
            }
            order.append(relative)
        }
    }

    private func parentForObject(_ relative: Data) throws -> (directory: OperationDirectory, name: Data) {
        try requireRoot()
        let components = relative.split(separator: 47, omittingEmptySubsequences: false).map { Data($0) }
        guard let name = components.last else { throw OperationFilesystemError.invalidPath }
        for component in components { try OperationDirectory.validateName(component) }
        var parent = directory
        var prefix = Data()
        for component in components.dropLast() {
            prefix = prefix.isEmpty ? component : prefix + Data([47]) + component
            guard let object = record.objects.first(where: { $0.name == prefix }), object.kind == .directory else {
                throw OperationFilesystemError.unexpectedContents
            }
            let observed = try parent.observe(component)
            guard observed.identity == object.identity, observed.kind == .directory else {
                throw OperationFilesystemError.identityChanged
            }
            let child = try OperationDirectory(path: parent.childPath(component))
            guard child.identity == object.identity else { throw OperationFilesystemError.identityChanged }
            parent = child
        }
        try parent.requireCurrentPath()
        return (parent, name)
    }

    private func requireRoot() throws {
        let root = try parent.observe(record.root.name)
        guard root.identity == record.root.identity, root.kind == .directory else {
            throw OperationFilesystemError.identityChanged
        }
    }
}
