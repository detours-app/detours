import Foundation

enum DetoursPreviewKind: Equatable {
    case markdown(language: String)
    case sourceCode(language: String)
    case configuration(language: String)
    case plainText(language: String)
    case unsupported

    var isSupported: Bool {
        self != .unsupported
    }

    var highlightLanguage: String {
        switch self {
        case .markdown(let language),
             .sourceCode(let language),
             .configuration(let language),
             .plainText(let language):
            return language
        case .unsupported:
            return "plaintext"
        }
    }

    var cacheComponent: String {
        switch self {
        case .markdown(let language): return "markdown-\(language)"
        case .sourceCode(let language): return "source-\(language)"
        case .configuration(let language): return "config-\(language)"
        case .plainText(let language): return "text-\(language)"
        case .unsupported: return "unsupported"
        }
    }

    static func classify(url: URL, sampleData: Data? = nil) -> DetoursPreviewKind {
        let baseKind = classifyByName(url.lastPathComponent)
        if baseKind == .unsupported {
            guard let sampleData, isTextLike(sampleData), url.pathExtension.isEmpty else {
                return .unsupported
            }
            return .plainText(language: "plaintext")
        }

        if let sampleData, !isTextLike(sampleData) {
            return .unsupported
        }
        return baseKind
    }

    static func isTextLike(_ data: Data) -> Bool {
        if data.isEmpty {
            return true
        }
        if data.contains(0) {
            return false
        }

        var suspiciousControlCount = 0
        for byte in data.prefix(8192) {
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) {
                suspiciousControlCount += 1
            }
        }
        if suspiciousControlCount > 0 {
            return false
        }

        if String(data: data, encoding: .utf8) != nil {
            return true
        }

        // Intentional lossy decode after failable UTF-8 decode rejected the data.
        // swiftlint:disable:next optional_data_string_conversion
        let lossyText = String(decoding: data, as: UTF8.self)
        let replacement = lossyText.filter { $0 == "\u{FFFD}" }.count
        return replacement <= max(1, data.count / 100)
    }

    private static func classifyByName(_ fileName: String) -> DetoursPreviewKind {
        let lowerName = fileName.lowercased()
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()

        if markdownExtensions.contains(ext) {
            return .markdown(language: "markdown")
        }
        if let language = sourceExtensions[ext] {
            return .sourceCode(language: language)
        }
        if let language = configurationExtensions[ext] {
            return .configuration(language: language)
        }
        if plainTextExtensions.contains(ext) {
            return .plainText(language: "plaintext")
        }
        if let language = exactNames[lowerName] {
            return .configuration(language: language)
        }
        if lowerName.hasPrefix(".env") {
            return .configuration(language: "ini")
        }
        return .unsupported
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
    private static let plainTextExtensions: Set<String> = ["txt", "text", "log"]

    private static let sourceExtensions: [String: String] = [
        "swift": "swift",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "py": "python",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "css": "css",
        "html": "xml",
        "htm": "xml",
        "xml": "xml",
        "sql": "sql",
        "diff": "diff",
        "patch": "diff"
    ]

    private static let configurationExtensions: [String: String] = [
        "json": "json",
        "jsonc": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "ini": "ini",
        "conf": "ini",
        "cfg": "ini",
        "plist": "xml"
    ]

    private static let exactNames: [String: String] = [
        ".gitignore": "plaintext",
        ".gitattributes": "plaintext",
        ".editorconfig": "ini",
        ".npmrc": "ini",
        ".zshrc": "bash",
        ".bashrc": "bash",
        "makefile": "plaintext",
        "dockerfile": "plaintext"
    ]
}
