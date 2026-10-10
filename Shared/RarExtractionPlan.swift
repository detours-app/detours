import Foundation
import RemoteOperationSupport

public struct RarExtractionPlan: Sendable {
    public let members: [SevenZipArchiveReader.Member]
    public let paths: [UInt32: Data]
    public let outputs: [UInt32: Data]
    public let directories: [Data]
    public let hardLinks: [UInt32: UInt32]
    public let singleRoot: String?
    public let byteCount: UInt64

    public init(_ members: [SevenZipArchiveReader.Member], caseSensitive: Bool) throws {
        self.members = members
        var names: [UInt32: [String]] = [:]
        var indexed: [String: UInt32] = [:]
        var spellings: [String: String] = [:]
        var roots = Set<String>()
        var total: UInt64 = 0
        func key(_ name: String) -> String {
            let normalized = name.precomposedStringWithCanonicalMapping
            return caseSensitive ? normalized : normalized.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        for (index, member) in members.enumerated() {
            guard member.index == index else { throw SevenZipArchiveError.invalidEntry }
            let parts = try Self.components(member.name)
            guard !parts.isEmpty else { throw SevenZipArchiveError.invalidEntry }
            let name = parts.joined(separator: "/")
            guard indexed[key(name)] == nil else { throw SevenZipArchiveError.invalidEntry }
            for count in 1...parts.count {
                let prefix = parts.prefix(count).joined(separator: "/")
                if let previous = spellings[key(prefix)], previous != prefix { throw SevenZipArchiveError.invalidEntry }
                spellings[key(prefix)] = prefix
            }
            let type = member.mode & 0o170000
            guard [UInt32(0), 0o100000, 0o040000, 0o120000].contains(type),
                  !member.directory || member.symbolicLink == nil && member.hardLink == nil,
                  member.symbolicLink == nil || member.hardLink == nil else { throw SevenZipArchiveError.invalidEntry }
            if !member.directory {
                guard let size = member.size, size <= UInt64(Int64.max) else { throw SevenZipArchiveError.invalidEntry }
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow, sum <= UInt64(Int64.max) else { throw SevenZipArchiveError.invalidEntry }
                total = sum
            }
            indexed[key(name)] = member.index
            names[member.index] = parts
            if let first = parts.first { roots.insert(first) }
        }
        guard !roots.isEmpty else { throw SevenZipArchiveError.invalidEntry }
        singleRoot = roots.count == 1 ? roots.first : nil
        var paths: [UInt32: Data] = [:]
        var outputs: [UInt32: Data] = [:]
        var directories = Set<Data>()
        var hardLinks: [UInt32: UInt32] = [:]
        if roots.count > 1 { directories.insert(Data("payload".utf8)) }
        for member in members {
            guard let parts = names[member.index] else { throw SevenZipArchiveError.invalidEntry }
            for count in 1..<parts.count {
                if let index = indexed[key(parts.prefix(count).joined(separator: "/"))] {
                    guard members[Int(index)].directory else { throw SevenZipArchiveError.invalidEntry }
                }
            }
            let relative = roots.count == 1 ? Array(parts.dropFirst()) : parts
            let target = Data((["payload"] + relative).joined(separator: "/").utf8)
            paths[member.index] = target
            for count in 0..<relative.count {
                directories.insert(Data((["payload"] + relative.prefix(count)).joined(separator: "/").utf8))
            }
            if member.directory {
                directories.insert(target)
            } else {
                let link = member.symbolicLink != nil || member.mode & 0o170000 == 0o120000 || member.hardLink != nil
                outputs[member.index] = link ? Data("archive-link-\(member.index)".utf8) : target
            }
            if let symbolic = member.symbolicLink { try Self.validateLink(symbolic, at: target) }
            if let hardLink = member.hardLink {
                let name = try Self.components(hardLink).joined(separator: "/")
                guard let source = indexed[key(name)], source != member.index,
                      !members[Int(source)].directory, members[Int(source)].symbolicLink == nil,
                      members[Int(source)].mode & 0o170000 != 0o120000 else { throw SevenZipArchiveError.invalidEntry }
                hardLinks[member.index] = source
            }
        }
        for index in hardLinks.keys {
            var visited = Set<UInt32>()
            var current = index
            while let next = hardLinks[current] {
                guard visited.insert(current).inserted else { throw SevenZipArchiveError.invalidEntry }
                current = next
            }
        }
        self.paths = paths
        self.outputs = outputs
        self.hardLinks = hardLinks
        self.byteCount = total
        self.directories = directories.sorted {
            let left = $0.filter { $0 == 47 }.count
            let right = $1.filter { $0 == 47 }.count
            return left == right ? $0.lexicographicallyPrecedes($1) : left < right
        }
    }

    public static func validateLink(_ target: String, at path: Data) throws {
        guard path.split(separator: 47).count >= 2, !target.isEmpty,
              !target.contains("\\"), !target.contains(":"), !target.contains("\0"),
              ArchiveToolDiagnostics.firstUnsafeMemberPath([target]) == nil else { throw SevenZipArchiveError.invalidEntry }
    }

    private static func components(_ name: String) throws -> [String] {
        guard !name.contains("\0"), !name.contains("\\"), !name.contains(":"),
              ArchiveToolDiagnostics.firstUnsafeMemberPath([name]) == nil else { throw SevenZipArchiveError.invalidEntry }
        return name.split(separator: "/").map(String.init).filter { $0 != "." }
    }
}
