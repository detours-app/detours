import DetoursProcess
import Foundation
import RemoteOperationSupport

struct ServerArchiveExtractionPlan: Sendable {
    let members: [SevenZipArchiveReader.Member]
    let paths: [UInt32: Data]
    let outputs: [UInt32: Data]
    let directories: [Data]
    let hardLinks: [UInt32: UInt32]

    init(_ members: [SevenZipArchiveReader.Member], rootName: String = "payload") throws {
        guard rootName == "payload" || rootName == "tree" else { throw SevenZipArchiveError.invalidEntry }
        self.members = members
        var names: [UInt32: [String]] = [:]
        var indexed: [String: UInt32] = [:]
        var roots = Set<String>()
        for (index, member) in members.enumerated() {
            guard member.index == index else { throw SevenZipArchiveError.invalidEntry }
            let parts = try Self.components(member.name)
            if parts.isEmpty {
                guard member.directory else { throw SevenZipArchiveError.invalidEntry }
                continue
            }
            let name = parts.joined(separator: "/")
            guard indexed[name] == nil else { throw SevenZipArchiveError.invalidEntry }
            let type = member.mode & 0o170000
            guard [UInt32(0), 0o100000, 0o040000, 0o120000].contains(type),
                  !member.directory || member.symbolicLink == nil && member.hardLink == nil else {
                throw SevenZipArchiveError.invalidEntry
            }
            indexed[name] = member.index
            names[member.index] = parts
            if let first = parts.first { roots.insert(first) }
        }
        guard !roots.isEmpty else { throw ArchiveOperationsError.emptyArchive("archive") }
        var paths: [UInt32: Data] = [:]
        var outputs: [UInt32: Data] = [:]
        var directories = Set<Data>()
        var hardLinks: [UInt32: UInt32] = [:]
        if roots.count > 1 { directories.insert(Data(rootName.utf8)) }
        for member in members {
            guard let parts = names[member.index] else { continue }
            for count in 1..<parts.count {
                if let index = indexed[parts.prefix(count).joined(separator: "/")] {
                    guard members[Int(index)].directory else { throw SevenZipArchiveError.invalidEntry }
                }
            }
            let relative = roots.count == 1 ? Array(parts.dropFirst()) : parts
            let target = Data(([rootName] + relative).joined(separator: "/").utf8)
            paths[member.index] = target
            for count in 0..<relative.count {
                directories.insert(Data(([rootName] + relative.prefix(count)).joined(separator: "/").utf8))
            }
            if member.directory {
                directories.insert(target)
            } else {
                let link = member.symbolicLink != nil || member.mode & 0o170000 == 0o120000 || member.hardLink != nil
                outputs[member.index] = link ? Data("archive-link-\(member.index)".utf8) : target
            }
            if let hardLink = member.hardLink {
                let name = try Self.components(hardLink).joined(separator: "/")
                guard let source = indexed[name], source != member.index,
                      !members[Int(source)].directory, members[Int(source)].symbolicLink == nil,
                      members[Int(source)].mode & 0o170000 != 0o120000 else { throw SevenZipArchiveError.invalidEntry }
                hardLinks[member.index] = source
            }
        }
        self.paths = paths
        self.outputs = outputs
        self.directories = directories.sorted {
            let left = $0.filter { $0 == 47 }.count
            let right = $1.filter { $0 == 47 }.count
            return left == right ? $0.lexicographicallyPrecedes($1) : left < right
        }
        self.hardLinks = hardLinks
    }

    private static func components(_ name: String) throws -> [String] {
        guard !name.contains("\0"), ArchiveToolDiagnostics.firstUnsafeMemberPath([name]) == nil else {
            throw SevenZipArchiveError.invalidEntry
        }
        return name.split(separator: "/").map(String.init).filter { $0 != "." }
    }
}
