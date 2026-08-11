import Foundation

enum DetoursPreviewKind: Equatable {
    case markdown(language: String)
    case htmlDocument(language: String)
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
             .htmlDocument(let language),
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
        case .htmlDocument(let language): return "html-\(language)"
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
        if htmlExtensions.contains(ext) {
            return .htmlDocument(language: "xml")
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
        for (prefix, language) in namePrefixes where lowerName.hasPrefix(prefix) {
            return .configuration(language: language)
        }
        return .unsupported
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
    private static let htmlExtensions: Set<String> = ["html", "htm"]
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
        "pyi": "python",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "fish": "bash",
        "ps1": "powershell",
        "css": "css",
        "scss": "css",
        "sass": "css",
        "less": "css",
        "xml": "xml",
        "vue": "xml",
        "svelte": "xml",
        "astro": "xml",
        "sql": "sql",
        "diff": "diff",
        "patch": "diff",
        "go": "go",
        "rs": "rust",
        "kt": "kotlin",
        "kts": "kotlin",
        "java": "java",
        "cs": "csharp",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hh": "cpp",
        "hxx": "cpp",
        "m": "objectivec",
        "mm": "objectivec",
        "php": "php",
        "rb": "ruby",
        "pl": "perl",
        "pm": "perl",
        "lua": "lua",
        "r": "r",
        "dart": "dart",
        "scala": "scala",
        "groovy": "groovy",
        "gradle": "groovy",
        "tf": "hcl",
        "tfvars": "hcl",
        "hcl": "hcl",
        "proto": "protobuf",
        "graphql": "graphql",
        "gql": "graphql",
        "ex": "elixir",
        "exs": "elixir",
        "hs": "haskell"
    ]

    private static let configurationExtensions: [String: String] = [
        "json": "json",
        "jsonc": "json",
        "jsonl": "json",
        "ndjson": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "ini": "ini",
        "conf": "ini",
        "cfg": "ini",
        "properties": "ini",
        "xcconfig": "ini",
        "env": "ini",
        "plist": "xml",
        "entitlements": "xml",
        "storyboard": "xml",
        "xib": "xml",
        "resolved": "json",
        "webmanifest": "json"
    ]

    private static let exactNames: [String: String] = [
        ".gitignore": "plaintext",
        ".gitattributes": "plaintext",
        ".dockerignore": "plaintext",
        ".editorconfig": "ini",
        ".npmrc": "ini",
        ".gitconfig": "ini",
        ".gitmodules": "ini",
        ".zshrc": "bash",
        ".zprofile": "bash",
        ".zshenv": "bash",
        ".bashrc": "bash",
        ".bash_profile": "bash",
        ".profile": "bash",
        ".prettierrc": "json",
        ".eslintrc": "json",
        ".babelrc": "json",
        "gemfile": "ruby",
        "rakefile": "ruby",
        "podfile": "ruby",
        "brewfile": "ruby",
        "justfile": "plaintext"
    ]

    /// Build files travel with suffixes (`Dockerfile.dev`, `Makefile.local`, `CMakeLists.txt`),
    /// so match the family rather than one exact spelling.
    private static let namePrefixes: [String: String] = [
        "makefile": "plaintext",
        "gnumakefile": "plaintext",
        "dockerfile": "plaintext",
        "cmakelists": "plaintext",
        ".env": "ini"
    ]
}
