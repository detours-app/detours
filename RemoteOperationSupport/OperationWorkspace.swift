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
        try OperationDirectory.validateName(name)
        let descriptor = try OperationDirectory.withBytes(name) {
            openat(directory.descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw OperationDirectory.systemError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw OperationDirectory.systemError() }
        let observation = try directory.observe(name)
        guard observation.identity == OperationDirectory.identity(info) else { throw OperationFilesystemError.identityChanged }
        record = Record(id: record.id, root: record.root,
                        objects: record.objects + [OperationOwnedObject(name: name, observation: observation)])
        try directory.synchronize()
        return handle
    }

    public func synchronizeFile(named name: Data) throws {
        try requireRoot()
        guard let owned = record.objects.first(where: { $0.name == name }), owned.kind == .file else {
            throw OperationFilesystemError.unexpectedContents
        }
        let descriptor = try OperationDirectory.withBytes(name) {
            openat(directory.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw OperationDirectory.systemError() }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw OperationDirectory.systemError() }
        guard OperationDirectory.identity(info) == owned.identity else { throw OperationFilesystemError.identityChanged }
        guard fsync(descriptor) == 0 else { throw OperationDirectory.systemError() }
    }

    public func removeScratch() throws {
        try requireRoot()
        let present = try directory.names()
        let expected = Set(record.objects.map(\.name))
        guard present.isSubset(of: expected) else { throw OperationFilesystemError.unexpectedContents }
        for object in record.objects where present.contains(object.name) {
            let observation = try directory.observe(object.name)
            guard observation.identity == object.identity, observation.kind == object.kind else {
                throw OperationFilesystemError.identityChanged
            }
        }
        for object in record.objects where present.contains(object.name) {
            let observation = try directory.observe(object.name)
            guard observation.identity == object.identity, observation.kind == .file else {
                throw OperationFilesystemError.identityChanged
            }
            let result = try OperationDirectory.withBytes(object.name) { unlinkat(directory.descriptor, $0, 0) }
            guard result == 0 else { throw OperationDirectory.systemError() }
        }
        try directory.synchronize()
        try requireRoot()
        let result = try OperationDirectory.withBytes(record.root.name) { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
        guard result == 0 else { throw OperationDirectory.systemError() }
        try parent.synchronize()
    }

    private func requireRoot() throws {
        let root = try parent.observe(record.root.name)
        guard root.identity == record.root.identity, root.kind == .directory else {
            throw OperationFilesystemError.identityChanged
        }
    }
}
