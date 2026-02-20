import Foundation

enum ArchiveFormat: String, CaseIterable, Codable {
    case zip
    case sevenZ
    case tarGz
    case tarBz2
    case tarXz

    var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZ: return "7Z"
        case .tarGz: return "TAR.GZ"
        case .tarBz2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZ: return "7z"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        }
    }

    var description: String {
        switch self {
        case .zip: return "Universal format. Compatible with all systems. Weak encryption."
        case .sevenZ: return "Best compression ratio. AES-256 encryption with filename hiding."
        case .tarGz: return "Standard Unix archive. Good compression speed. No encryption."
        case .tarBz2: return "Better compression ratio than gzip. Slower. No encryption."
        case .tarXz: return "Best compression for tar archives. Slowest. No encryption."
        }
    }

    var supportsPassword: Bool {
        switch self {
        case .zip, .sevenZ: return true
        case .tarGz, .tarBz2, .tarXz: return false
        }
    }

    var requiredTools: [CompressionTool] {
        switch self {
        case .zip: return [.zip]
        case .sevenZ: return [.sevenZip]
        case .tarGz: return [.tar]
        case .tarBz2: return [.tar]
        case .tarXz: return [.tar, .xz]
        }
    }

    var extractionTools: [CompressionTool] {
        switch self {
        case .zip: return [.ditto]
        case .sevenZ: return [.sevenZip]
        case .tarGz, .tarBz2, .tarXz: return [.tar]
        }
    }

    static func detect(from url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") { return .tarBz2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        switch url.pathExtension.lowercased() {
        case "zip": return .zip
        case "7z": return .sevenZ
        default: return nil
        }
    }
}

enum CompressionTool: String {
    case zip
    case unzip
    case sevenZip
    case tar
    case gzip
    case bzip2
    case xz
    case ditto

    var path: String {
        switch self {
        case .zip: return "/usr/bin/zip"
        case .unzip: return "/usr/bin/unzip"
        case .sevenZip: return "/opt/homebrew/bin/7z"
        case .tar: return "/usr/bin/tar"
        case .gzip: return "/usr/bin/gzip"
        case .bzip2: return "/usr/bin/bzip2"
        case .xz: return "/opt/homebrew/bin/xz"
        case .ditto: return "/usr/bin/ditto"
        }
    }

    var displayName: String {
        switch self {
        case .zip: return "zip"
        case .unzip: return "unzip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .gzip: return "gzip"
        case .bzip2: return "bzip2"
        case .xz: return "xz"
        case .ditto: return "ditto"
        }
    }
}

enum CompressionTools {
    nonisolated(unsafe) private static var cache: [CompressionTool: Bool] = [:]

    static func isAvailable(_ tool: CompressionTool) -> Bool {
        if let cached = cache[tool] {
            return cached
        }
        let available = FileManager.default.fileExists(atPath: tool.path)
        cache[tool] = available
        return available
    }

    static func isFormatAvailable(_ format: ArchiveFormat) -> Bool {
        format.requiredTools.allSatisfy { isAvailable($0) }
    }

    static func unavailableToolName(for format: ArchiveFormat) -> String? {
        for tool in format.requiredTools where !isAvailable(tool) {
            return tool.displayName
        }
        return nil
    }

    static func canExtract(_ format: ArchiveFormat) -> Bool {
        format.extractionTools.allSatisfy { isAvailable($0) }
    }

    static func isExtractable(_ url: URL) -> Bool {
        guard let format = ArchiveFormat.detect(from: url) else { return false }
        return canExtract(format)
    }
}
