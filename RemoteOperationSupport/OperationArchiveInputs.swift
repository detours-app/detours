import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct OperationArchiveInputs: Sendable {
    public let manifest: OperationManifest
    public let locations: [Data: Data]
}

private struct ArchiveInputCollection {
    let followingLinks: Bool
    var entries: [OperationManifest.Entry] = []
    var locations: [Data: Data] = [:]
    var measured: UInt64 = 0
}

extension OperationDirectory {
    public func archiveInputs(_ name: Data, followingLinks: Bool,
                              progress: (UInt64) throws -> Void) throws -> OperationArchiveInputs {
        var collection = ArchiveInputCollection(followingLinks: followingLinks)
        try collectArchiveInputs(name, relative: Data(), ancestors: [], collection: &collection, progress: progress)
        return OperationArchiveInputs(manifest: try OperationManifest(entries: collection.entries), locations: collection.locations)
    }

    private func collectArchiveInputs(_ name: Data, relative: Data, ancestors: Set<OperationObjectIdentity>,
                                      collection: inout ArchiveInputCollection, progress: (UInt64) throws -> Void) throws {
        try progress(collection.measured)
        try requireCurrentPath()
        let before = try observe(name)
        if before.kind == .symbolicLink, collection.followingLinks {
            let resolved = try resolvedArchiveLink(name)
            guard let slash = resolved.lastIndex(of: 47), slash < resolved.index(before: resolved.endIndex) else {
                throw OperationFilesystemError.unsupported
            }
            let parentPath = slash == resolved.startIndex ? Data([47]) : Data(resolved[..<slash])
            let targetName = Data(resolved[resolved.index(after: slash)...])
            let parent = try OperationDirectory(path: parentPath)
            try parent.collectArchiveInputs(targetName, relative: relative, ancestors: ancestors,
                                            collection: &collection, progress: progress)
        } else {
            collection.locations[relative] = try childPath(name)
            switch before.kind {
            case .file:
                let base = collection.measured
                let proved = try proveFile(name) { count in
                    let (total, overflow) = base.addingReportingOverflow(count)
                    guard !overflow else { throw OperationFilesystemError.unsupported }
                    try progress(total)
                }
                guard proved.identity == before.identity, proved.version == before.version else {
                    throw OperationFilesystemError.identityChanged
                }
                let (total, overflow) = collection.measured.addingReportingOverflow(proved.byteCount)
                guard !overflow else { throw OperationFilesystemError.unsupported }
                collection.measured = total
                collection.entries.append(.init(relativePath: relative, observation: proved))
            case .symbolicLink:
                collection.entries.append(.init(relativePath: relative, observation: before))
            case .directory:
                guard !ancestors.contains(before.identity) else { throw OperationFilesystemError.unsupported }
                let child = try OperationDirectory(path: childPath(name))
                guard child.identity == before.identity else { throw OperationFilesystemError.identityChanged }
                let names = try child.names()
                collection.entries.append(.init(relativePath: relative, observation: before))
                let parents = ancestors.union([before.identity])
                for member in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    let path = relative.isEmpty ? member : relative + Data([47]) + member
                    try child.collectArchiveInputs(member, relative: path, ancestors: parents,
                                                   collection: &collection, progress: progress)
                }
                guard try child.names() == names else { throw OperationFilesystemError.identityChanged }
                try child.requireCurrentPath()
            }
        }
        guard try observe(name) == before else { throw OperationFilesystemError.identityChanged }
        try requireCurrentPath()
        try progress(collection.measured)
    }

    private func resolvedArchiveLink(_ name: Data) throws -> Data {
        let path = try childPath(name)
        guard let resolved = try Self.withBytes(path, { realpath($0, nil) }) else { throw Self.systemError() }
        defer { free(resolved) }
        return Data(bytes: resolved, count: strlen(resolved))
    }
}
