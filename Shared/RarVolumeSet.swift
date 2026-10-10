import Foundation
import RemoteOperationSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns a pinned parent directory, never a descriptor for every archive part.
public final class RarVolumeSet: @unchecked Sendable {
    public struct Part: Equatable, Sendable {
        public let name: String
        public let observation: OperationObservation

        public init(name: String, observation: OperationObservation) {
            self.name = name
            self.observation = observation
        }
    }

    public let directory: OperationDirectory
    public let parts: [Part]
    public let format: SevenZipArchiveReader.Format
    public let members: [SevenZipArchiveReader.Member]
    public let baseName: String

    private init(directory: OperationDirectory, parts: [Part], format: SevenZipArchiveReader.Format,
                 members: [SevenZipArchiveReader.Member], baseName: String) {
        self.directory = directory
        self.parts = parts
        self.format = format
        self.members = members
        self.baseName = baseName
    }

    public static func isCandidate(_ name: String) -> Bool { Naming(name) != nil }

    public static func discover(directory: OperationDirectory, selected: String, password: String?,
                                progress: @escaping @Sendable (UInt64) throws -> Void) throws -> RarVolumeSet {
        guard let selectedNaming = Naming(selected) else { throw SevenZipArchiveError.invalidEntry }
        let names = try directory.names().compactMap { String(data: $0, encoding: .utf8) }
        let selectedName = try resolve(selected, among: names)
        let selectedProof = try directory.proveFile(Data(selectedName.utf8), progress: progress)
        let input = try directory.openObservedFile(Data(selectedName.utf8), expected: selectedProof)
        defer { try? input.close() }
        let format = try signature(input)
        let selectedHeader = try SevenZipArchiveReader.inspectRarVolume(input: input, format: format,
                                                                         password: password, progress: progress)
        let firstName = try resolve(selectedHeader.isVolume ? selectedNaming.first : selectedName, among: names)
        let discovery = Discovery(directory: directory, names: names, format: format,
                                  password: password, progress: progress)
        let first = try discovery.open(firstName)
        defer { try? first.close() }
        let members = try SevenZipArchiveReader.read(input: first, format: format, password: password,
            inputName: firstName, openVolume: { try discovery.open($0) }, progress: progress)
        guard discovery.parts.contains(where: { $0.name == selectedName && $0.observation == selectedProof }) else {
            throw SevenZipArchiveError.inconsistentVolumes(selectedName)
        }
        let set = RarVolumeSet(directory: directory, parts: discovery.parts, format: format, members: members,
                               baseName: selectedHeader.isVolume ? selectedNaming.base : String(selectedName.dropLast(4)))
        try set.validate(progress: progress)
        if members.contains(where: \.encrypted), password?.isEmpty != false { throw SevenZipArchiveError.passwordRequired }
        return set
    }

    public static func accepted(directory: OperationDirectory, parts: [Part], password: String?,
                                progress: @escaping @Sendable (UInt64) throws -> Void) throws -> RarVolumeSet {
        guard parts.count <= 1_024 else { throw SevenZipArchiveError.volumeLimitExceeded }
        guard let first = parts.first,
              Set(parts.map(\.name)).count == parts.count,
              parts.allSatisfy({ $0.observation.kind == .file && $0.observation.sha256 != nil }) else {
            throw SevenZipArchiveError.invalidEntry
        }
        let input = try directory.openObservedFile(Data(first.name.utf8), expected: first.observation)
        defer { try? input.close() }
        let format = try signature(input)
        let set = RarVolumeSet(directory: directory, parts: parts, format: format, members: [],
                               baseName: Naming(first.name)?.base ?? first.name)
        try set.validate(progress: progress)
        let members = try set.read(password: password, progress: progress)
        return RarVolumeSet(directory: directory, parts: parts, format: format, members: members, baseName: set.baseName)
    }

    public func validate(progress: @escaping @Sendable (UInt64) throws -> Void) throws {
        try directory.requireCurrentPath()
        for part in parts {
            guard try directory.proveFile(Data(part.name.utf8), progress: progress) == part.observation else {
                throw OperationFilesystemError.identityChanged
            }
        }
    }

    public func read(password: String?, output: (@Sendable (SevenZipArchiveReader.Member) throws -> FileHandle)? = nil,
                     progress: @escaping @Sendable (UInt64) throws -> Void) throws -> [SevenZipArchiveReader.Member] {
        guard let first = parts.first else { throw SevenZipArchiveError.invalidEntry }
        let input = try openAccepted(first.name)
        defer { try? input.close() }
        return try SevenZipArchiveReader.read(input: input, format: format, password: password,
            inputName: first.name, openVolume: { try self.openAccepted($0) }, output: output, progress: progress)
    }

    private func openAccepted(_ name: String) throws -> FileHandle {
        guard Naming(name) != nil else { throw SevenZipArchiveError.invalidEntry }
        let resolved = try Self.resolve(name, among: parts.map(\.name))
        guard let part = parts.first(where: { $0.name == resolved }) else { throw SevenZipArchiveError.missingVolume(name) }
        try directory.requireCurrentPath()
        return try directory.openObservedFile(Data(part.name.utf8), expected: part.observation)
    }

    static func resolve(_ name: String, among names: [String]) throws -> String {
        let matches = names.filter { $0.lowercased() == name.lowercased() }
        guard matches.count <= 1 else { throw SevenZipArchiveError.ambiguousVolumes(name) }
        guard let match = matches.first else { throw SevenZipArchiveError.missingVolume(name) }
        return match
    }

    private static func signature(_ input: FileHandle) throws -> SevenZipArchiveReader.Format {
        var bytes = [UInt8](repeating: 0, count: 8)
        guard pread(input.fileDescriptor, &bytes, bytes.count, 0) == bytes.count else {
            throw SevenZipArchiveError.corruptArchive
        }
        if bytes == [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00] { return .rar5 }
        if bytes.prefix(7) == [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00] { return .rar }
        throw SevenZipArchiveError.corruptArchive
    }

    private struct Naming {
        let first: String
        let base: String
        let index: Int

        init?(_ name: String) {
            guard !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else { return nil }
            let lower = name.lowercased()
            if lower.hasSuffix(".rar") {
                let stem = String(name.dropLast(4))
                if let range = stem.range(of: ".part", options: [.backwards, .caseInsensitive]) {
                    let digits = String(stem[range.upperBound...])
                    if !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(digits), number > 0 {
                        self.base = String(stem[..<range.lowerBound])
                        self.first = String(stem[..<range.upperBound]) + String(repeating: "0", count: digits.count - 1) + "1" + name.suffix(4)
                        self.index = number - 1
                        return
                    }
                }
                self.base = stem
                self.first = name
                self.index = 0
                return
            }
            guard name.count > 4 else { return nil }
            let suffix = Array(lower.suffix(4).utf8)
            guard suffix[0] == 46, (114...122).contains(suffix[1]),
                  (48...57).contains(suffix[2]), (48...57).contains(suffix[3]) else { return nil }
            self.base = String(name.dropLast(4))
            self.first = base + ".rar"
            self.index = 1 + Int(suffix[1] - 114) * 100 + Int(suffix[2] - 48) * 10 + Int(suffix[3] - 48)
        }
    }

    private final class Discovery: @unchecked Sendable {
        let directory: OperationDirectory
        let names: [String]
        let format: SevenZipArchiveReader.Format
        let password: String?
        let progress: @Sendable (UInt64) throws -> Void
        var parts: [Part] = []
        var previous: SevenZipArchiveReader.RarVolume?

        init(directory: OperationDirectory, names: [String], format: SevenZipArchiveReader.Format,
             password: String?, progress: @escaping @Sendable (UInt64) throws -> Void) {
            self.directory = directory
            self.names = names
            self.format = format
            self.password = password
            self.progress = progress
        }

        func open(_ requested: String) throws -> FileHandle {
            guard let naming = Naming(requested) else { throw SevenZipArchiveError.invalidEntry }
            let name = try resolve(requested, among: names)
            try directory.requireCurrentPath()
            if let part = parts.first(where: { $0.name == name }) {
                return try directory.openObservedFile(Data(name.utf8), expected: part.observation)
            }
            guard parts.count < 1_024 else { throw SevenZipArchiveError.volumeLimitExceeded }
            let proof = try directory.proveFile(Data(name.utf8), progress: progress)
            guard !parts.contains(where: { $0.observation.identity == proof.identity }) else {
                throw SevenZipArchiveError.inconsistentVolumes(name)
            }
            let input = try directory.openObservedFile(Data(name.utf8), expected: proof)
            do {
                guard try signature(input) == format else { throw SevenZipArchiveError.inconsistentVolumes(name) }
                let header = try SevenZipArchiveReader.inspectRarVolume(input: input, format: format,
                                                                         password: password, progress: progress)
                if header.isVolume {
                    guard naming.index == parts.count, header.index == nil || header.index == UInt32(parts.count) else {
                        throw SevenZipArchiveError.inconsistentVolumes(name)
                    }
                } else if !parts.isEmpty { throw SevenZipArchiveError.inconsistentVolumes(name) }
                let first = header.members.first
                if let previous {
                    guard previous.isVolume, header.isVolume,
                          previous.members.last?.splitAfter == first?.splitBefore else {
                        throw SevenZipArchiveError.inconsistentVolumes(name)
                    }
                    if let last = previous.members.last, last.splitAfter {
                        guard let first, last.name == first.name, last.size == first.size,
                              last.encrypted == first.encrypted, last.directory == first.directory else {
                            throw SevenZipArchiveError.inconsistentVolumes(name)
                        }
                    }
                } else if first?.splitBefore == true { throw SevenZipArchiveError.inconsistentVolumes(name) }
                parts.append(Part(name: name, observation: proof))
                previous = header
                return input
            } catch {
                try? input.close()
                throw error
            }
        }
    }
}
