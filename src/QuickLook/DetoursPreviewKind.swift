import Foundation

enum DetoursPreviewKind: Equatable {
    case markdown(language: String)
    case htmlDocument(language: String)
    case sourceCode(language: String)
    case configuration(language: String)
    case plainText(language: String)
    case delimitedTable(delimiter: Character)
    case wordDocument
    case spreadsheet
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
        case .delimitedTable, .wordDocument, .spreadsheet, .unsupported:
            // A grid and a document are written piece by piece and never run through the
            // highlighter.
            return "plaintext"
        }
    }

    /// Whether the file's own bytes are the text the preview draws.
    ///
    /// A data file decides its own encoding, and an Office container is not text at all, so putting
    /// either through the shared text decode would raise a lossy notice over a readable preview.
    var readsAsText: Bool {
        switch self {
        case .markdown, .htmlDocument, .sourceCode, .configuration, .plainText:
            return true
        case .delimitedTable, .wordDocument, .spreadsheet, .unsupported:
            return false
        }
    }

    /// Whether a file of this kind can degrade to the plain-text fallback when it is too large, too
    /// slow, or too big once drawn.
    ///
    /// A container of compressed parts cannot: read as text it is a screenful of noise, so it goes
    /// to the system preview, which can still show the reader their document.
    var hasPlainTextFallback: Bool {
        switch self {
        case .markdown, .htmlDocument, .sourceCode, .configuration, .plainText, .delimitedTable, .unsupported:
            return true
        case .wordDocument, .spreadsheet:
            return false
        }
    }

    var cacheComponent: String {
        switch self {
        case .markdown(let language): return "markdown-\(language)"
        case .htmlDocument(let language): return "html-\(language)"
        case .sourceCode(let language): return "source-\(language)"
        case .configuration(let language): return "config-\(language)"
        case .plainText(let language): return "text-\(language)"
        case .delimitedTable(let delimiter): return "delimited-\(delimiter.unicodeScalars.first?.value ?? 0)"
        case .wordDocument: return "word"
        case .spreadsheet: return "spreadsheet"
        case .unsupported: return "unsupported"
        }
    }

    static func classify(url: URL, sampleData: Data? = nil) -> DetoursPreviewKind {
        let baseKind = classifyByName(url.lastPathComponent)
        if baseKind == .unsupported {
            // An unfamiliar suffix is not a reason to refuse a file whose bytes are plainly text.
            // Tools invent their own endings constantly, so the bytes decide, and the short list of
            // formats macOS draws better than any text preview could is the only thing held back.
            let ext = url.pathExtension.lowercased()
            guard let sampleData, isTextLike(sampleData), !systemPreviewExtensions.contains(ext) else {
                return .unsupported
            }
            return .plainText(language: "plaintext")
        }

        // An Office file is a container of compressed parts, so its own bytes always sniff as
        // binary. Disqualifying it on that would rule out the only two formats read from a
        // container rather than from text.
        if baseKind == .wordDocument || baseKind == .spreadsheet {
            return baseKind
        }

        if let sampleData, !isTextLike(sampleData) {
            return .unsupported
        }
        return baseKind
    }

    /// Whether the bytes open with a UTF-16 byte order mark.
    ///
    /// Windows writes registry exports and a good deal of tool output as UTF-16, which carries a NUL
    /// beside every Latin character and would otherwise be turned away as binary.
    static func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
        let prefix = Array(data.prefix(2))
        return prefix == [0xFF, 0xFE] || prefix == [0xFE, 0xFF]
    }

    static func isTextLike(_ data: Data) -> Bool {
        if data.isEmpty {
            return true
        }
        if hasUTF16ByteOrderMark(data) {
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
        if ext == "docx" {
            return .wordDocument
        }
        if ext == "xlsx" {
            return .spreadsheet
        }
        if let delimiter = DetoursDelimitedTable.delimiterHint(forExtension: ext) {
            // The extension only implies a separator. The one actually used is decided from the
            // file's own content when the preview is built.
            return .delimitedTable(delimiter: delimiter)
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

    /// Formats macOS draws better than any text preview could, held back from the sniffed fallback.
    ///
    /// Each one is text underneath, so the byte check alone would take them and replace a rendered
    /// page or drawing with its markup.
    private static let systemPreviewExtensions: Set<String> = [
        "svg", "pdf", "ps", "eps", "ai", "rtf", "rtfd", "dxf", "webloc", "url", "ics", "vcf"
    ]

    private static let plainTextExtensions: Set<String> = [
        "txt", "text", "log",
        // Scan and tooling output: nmap's own two text formats, intrusion rules, and the wordlists,
        // hash lists and cracking artefacts a security assessment fills a folder with.
        "nmap", "gnmap", "rules", "lst", "dic", "wordlist", "hash", "hashes", "pot", "rule",
        "hcmask", "zone", "rc",
        // Armoured keys, certificates and signatures. All text; anything binary that borrows one of
        // these endings is turned away by the byte check.
        "pem", "crt", "cer", "csr", "key", "pub", "asc", "sig"
    ]

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
        "hs": "haskell",
        // Security tooling: nmap's scripting engine is Lua, a Nessus report and the classic server
        // page payloads are markup, and detection rules read as braces and strings.
        "nse": "lua",
        "nessus": "xml",
        "jsp": "xml",
        "jspx": "xml",
        "asp": "xml",
        "aspx": "xml",
        "yar": "c",
        "yara": "c",
        "psm1": "powershell",
        "psd1": "powershell",
        // Windows scripting has no colouring rules of its own here, so it is shown plainly rather
        // than coloured by the wrong language's keywords.
        "bat": "plaintext",
        "cmd": "plaintext",
        "vbs": "plaintext"
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
        "webmanifest": "json",
        // A captured web session is JSON; registry exports, VPN profiles and directory dumps all
        // read as sections and key/value pairs.
        "har": "json",
        "reg": "ini",
        "ovpn": "ini",
        "ldif": "ini",
        "eml": "ini"
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
        "justfile": "plaintext",
        "sshd_config": "ini",
        "ssh_config": "ini",
        "known_hosts": "plaintext",
        "authorized_keys": "plaintext",
        "id_rsa": "plaintext",
        "id_dsa": "plaintext",
        "id_ecdsa": "plaintext",
        "id_ed25519": "plaintext",
        ".netrc": "ini",
        ".htpasswd": "ini",
        ".htaccess": "ini",
        "hosts": "ini"
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
