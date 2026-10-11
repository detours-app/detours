import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ArchiveExtractionLayout {
    public static func singleRoot(input: FileHandle, format: SevenZipArchiveReader.Format, password: String?,
                                  progress: @escaping @Sendable (UInt64) throws -> Void) throws -> String? {
        let members: [SevenZipArchiveReader.Member]
        if [.gzip, .bzip2, .xz].contains(format) {
            guard password?.isEmpty != false else { throw SevenZipArchiveError.invalidEntry }
            guard let temporary = tmpfile() else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { fclose(temporary) }
            let temporaryDescriptor = fileno(temporary)
            _ = try SevenZipArchiveReader.read(input: input, format: format, password: nil, output: { member in
                guard member.index == 0, !member.directory, member.symbolicLink == nil, member.hardLink == nil else {
                    throw SevenZipArchiveError.invalidEntry
                }
                let descriptor = dup(temporaryDescriptor)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            }, progress: progress)
            let descriptor = dup(temporaryDescriptor)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let decoded = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? decoded.close() }
            try decoded.seek(toOffset: 0)
            members = try SevenZipArchiveReader.read(input: decoded, format: .tar, password: nil, progress: progress)
        } else {
            members = try SevenZipArchiveReader.read(input: input, format: format, password: password, progress: progress)
        }
        return try singleRoot(members: members, password: password)
    }

    public static func singleRoot(members: [SevenZipArchiveReader.Member], password: String?) throws -> String? {
        var roots: Set<String> = []
        if members.contains(where: \.encrypted), password?.isEmpty != false { throw SevenZipArchiveError.passwordRequired }
        for member in members {
            guard !member.name.contains("\0"), ArchiveToolDiagnostics.firstUnsafeMemberPath([member.name]) == nil else {
                throw SevenZipArchiveError.invalidEntry
            }
            if let root = member.name.split(separator: "/").first(where: { $0 != "." }) { roots.insert(String(root)) }
        }
        guard !roots.isEmpty else { throw SevenZipArchiveError.invalidEntry }
        return roots.count == 1 ? roots.first : nil
    }
}
