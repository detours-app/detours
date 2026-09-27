import Foundation

public struct OperationManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let relativePath: Data
        public let observation: OperationObservation
    }

    public let entries: [Entry]
    public let proof: OperationContentProof

    public func matchesMovedObjects(_ actual: OperationManifest) -> Bool {
        proof == actual.proof && entries.count == actual.entries.count && zip(entries, actual.entries).allSatisfy { before, after in
            before.relativePath == after.relativePath && before.observation.identity == after.observation.identity &&
                before.observation.kind == after.observation.kind && before.observation.linkTarget == after.observation.linkTarget &&
                before.observation.contentVersion == after.observation.contentVersion
        }
    }

    public static func combining(_ trees: [(prefix: Data, manifest: OperationManifest)]) throws -> OperationManifest {
        var combined: [Data: OperationObservation] = [:]
        for tree in trees {
            let components = tree.prefix.split(separator: 47, omittingEmptySubsequences: false)
            guard !components.isEmpty else { throw OperationFilesystemError.invalidPath }
            for component in components { try OperationDirectory.validateName(Data(component)) }
            for entry in tree.manifest.entries {
                let path = tree.prefix + (entry.relativePath.isEmpty ? Data() : Data([47]) + entry.relativePath)
                if let previous = combined[path], previous != entry.observation { throw OperationFilesystemError.identityChanged }
                combined[path] = entry.observation
            }
        }
        return try OperationManifest(entries: combined.map { Entry(relativePath: $0.key, observation: $0.value) })
    }

    init(entries: [Entry]) throws {
        let sorted = entries.sorted { $0.relativePath.lexicographicallyPrecedes($1.relativePath) }
        let payload = sorted.map { entry in
            PayloadEntry(relativePath: entry.relativePath, kind: entry.observation.kind,
                         byteCount: entry.observation.kind == .file ? entry.observation.byteCount : 0,
                         sha256: entry.observation.sha256, linkTarget: entry.observation.linkTarget)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = try OperationContentProof.data(encoder.encode(payload))
        var total: UInt64 = 0
        for entry in payload {
            let (sum, overflow) = total.addingReportingOverflow(entry.byteCount)
            guard !overflow else { throw OperationFilesystemError.unsupported }
            total = sum
        }
        self.entries = sorted
        self.proof = OperationContentProof(byteCount: total, sha256: digest.sha256)
    }

    private struct PayloadEntry: Codable {
        let relativePath: Data
        let kind: OperationObservation.Kind
        let byteCount: UInt64
        let sha256: String?
        let linkTarget: Data?
    }
}

extension OperationDirectory {
    public func proveObject(_ name: Data, progress: (UInt64) throws -> Void) throws -> OperationObservation {
        let observed = try observe(name)
        if observed.kind == .file { return try proveFile(name, progress: progress) }
        let manifest = try manifest(name, progress: progress)
        guard manifest.entries.first?.relativePath.isEmpty == true,
              manifest.entries.first?.observation == observed else { throw OperationFilesystemError.identityChanged }
        return OperationObservation(identity: observed.identity, kind: observed.kind, version: observed.version,
                                    byteCount: observed.byteCount, sha256: manifest.proof.sha256,
                                    linkTarget: observed.linkTarget, contentVersion: observed.contentVersion)
    }

    public func manifest(_ name: Data, progress: (UInt64) throws -> Void) throws -> OperationManifest {
        var entries: [OperationManifest.Entry] = []
        var measured: UInt64 = 0
        try collectManifest(name, relativePath: Data(), entries: &entries, measured: &measured, progress: progress)
        return try OperationManifest(entries: entries)
    }

    private func collectManifest(_ name: Data, relativePath: Data, entries: inout [OperationManifest.Entry],
                                 measured: inout UInt64, progress: (UInt64) throws -> Void) throws {
        try progress(measured)
        try requireCurrentPath()
        let before = try observe(name)
        switch before.kind {
        case .file:
            let base = measured
            let proved = try proveFile(name) { count in
                let (total, overflow) = base.addingReportingOverflow(count)
                guard !overflow else { throw OperationFilesystemError.unsupported }
                try progress(total)
            }
            guard proved.identity == before.identity, proved.version == before.version else {
                throw OperationFilesystemError.identityChanged
            }
            let (total, overflow) = measured.addingReportingOverflow(proved.byteCount)
            guard !overflow else { throw OperationFilesystemError.unsupported }
            measured = total
            entries.append(.init(relativePath: relativePath, observation: proved))
        case .symbolicLink:
            entries.append(.init(relativePath: relativePath, observation: before))
        case .directory:
            let child = try OperationDirectory(path: childPath(name))
            guard child.identity == before.identity else { throw OperationFilesystemError.identityChanged }
            let names = try child.names()
            entries.append(.init(relativePath: relativePath, observation: before))
            for member in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let relative = relativePath.isEmpty ? member : relativePath + Data([47]) + member
                try child.collectManifest(member, relativePath: relative, entries: &entries, measured: &measured, progress: progress)
            }
            guard try child.names() == names else { throw OperationFilesystemError.identityChanged }
            try child.requireCurrentPath()
        }
        guard try observe(name) == before else { throw OperationFilesystemError.identityChanged }
        try requireCurrentPath()
        try progress(measured)
    }
}
