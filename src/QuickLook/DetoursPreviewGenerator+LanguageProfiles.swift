import Foundation

/// Line-oriented highlighting rules for the languages whose colouring differs only in
/// which words are keywords and how a comment starts. Languages needing real structure
/// (JSON, XML, CSS, config files, diffs, Markdown) keep their own routines.
extension DetoursPreviewGenerator {
    struct LanguageProfile {
        let commentMarker: String
        let keywords: Set<String>
        let literals: Set<String>
        var caseInsensitiveKeywords = false
    }

    static let languageProfiles: [String: LanguageProfile] = [
        "swift": LanguageProfile(commentMarker: "//", keywords: swiftKeywords, literals: commonLiterals),
        "javascript": LanguageProfile(commentMarker: "//", keywords: javascriptKeywords, literals: commonLiterals),
        "typescript": LanguageProfile(commentMarker: "//", keywords: javascriptKeywords, literals: commonLiterals),
        "python": LanguageProfile(commentMarker: "#", keywords: pythonKeywords, literals: pythonLiterals),
        "bash": LanguageProfile(commentMarker: "#", keywords: bashKeywords, literals: commonLiterals),
        "sql": LanguageProfile(
            commentMarker: "--",
            keywords: sqlKeywords,
            literals: commonLiterals,
            caseInsensitiveKeywords: true
        ),
        "go": LanguageProfile(commentMarker: "//", keywords: goKeywords, literals: goLiterals),
        "rust": LanguageProfile(commentMarker: "//", keywords: rustKeywords, literals: rustLiterals),
        "kotlin": LanguageProfile(commentMarker: "//", keywords: kotlinKeywords, literals: kotlinLiterals),
        "java": LanguageProfile(commentMarker: "//", keywords: javaKeywords, literals: javaLiterals),
        "csharp": LanguageProfile(commentMarker: "//", keywords: csharpKeywords, literals: commonLiterals),
        "c": LanguageProfile(commentMarker: "//", keywords: cKeywords, literals: cLiterals),
        "cpp": LanguageProfile(commentMarker: "//", keywords: cppKeywords, literals: cLiterals),
        "objectivec": LanguageProfile(commentMarker: "//", keywords: objectiveCKeywords, literals: cLiterals),
        "php": LanguageProfile(commentMarker: "//", keywords: phpKeywords, literals: phpLiterals),
        "ruby": LanguageProfile(commentMarker: "#", keywords: rubyKeywords, literals: rubyLiterals),
        "perl": LanguageProfile(commentMarker: "#", keywords: perlKeywords, literals: commonLiterals),
        "lua": LanguageProfile(commentMarker: "--", keywords: luaKeywords, literals: commonLiterals),
        "r": LanguageProfile(commentMarker: "#", keywords: rKeywords, literals: rLiterals),
        "dart": LanguageProfile(commentMarker: "//", keywords: dartKeywords, literals: commonLiterals),
        "scala": LanguageProfile(commentMarker: "//", keywords: scalaKeywords, literals: commonLiterals),
        "groovy": LanguageProfile(commentMarker: "//", keywords: groovyKeywords, literals: commonLiterals),
        "hcl": LanguageProfile(commentMarker: "#", keywords: hclKeywords, literals: commonLiterals),
        "protobuf": LanguageProfile(commentMarker: "//", keywords: protobufKeywords, literals: commonLiterals),
        "graphql": LanguageProfile(commentMarker: "#", keywords: graphqlKeywords, literals: commonLiterals),
        "powershell": LanguageProfile(
            commentMarker: "#",
            keywords: powershellKeywords,
            literals: commonLiterals,
            caseInsensitiveKeywords: true
        ),
        "elixir": LanguageProfile(commentMarker: "#", keywords: elixirKeywords, literals: elixirLiterals),
        "haskell": LanguageProfile(commentMarker: "--", keywords: haskellKeywords, literals: commonLiterals)
    ]

    static let commonLiterals: Set<String> = ["true", "false", "null", "nil"]

    static let swiftKeywords: Set<String> = [
        "actor", "as", "associatedtype", "await", "break", "case", "catch", "class", "continue",
        "default", "defer", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
        "nil", "open", "operator", "private", "protocol", "public", "repeat", "return", "self",
        "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
        "typealias", "var", "where", "while"
    ]
    static let javascriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if",
        "import", "in", "instanceof", "interface", "let", "new", "of", "return", "switch", "throw",
        "try", "type", "typeof", "var", "void", "while", "with", "yield"
    ]
    static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
        "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
        "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"
    ]
    static let pythonLiterals: Set<String> = ["True", "False", "None"]
    static let bashKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
        "then", "until", "while"
    ]
    static let sqlKeywords: Set<String> = [
        "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CREATE", "DELETE", "DESC", "DISTINCT",
        "DROP", "ELSE", "END", "FROM", "GROUP", "HAVING", "IN", "INSERT", "INTO", "IS", "JOIN",
        "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "RIGHT", "SELECT", "SET",
        "TABLE", "THEN", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE"
    ]
    static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
        "return", "select", "struct", "switch", "type", "var"
    ]
    static let goLiterals: Set<String> = ["true", "false", "nil", "iota"]
    static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
        "pub", "ref", "return", "self", "static", "struct", "super", "trait", "type", "unsafe",
        "use", "where", "while"
    ]
    static let rustLiterals: Set<String> = ["true", "false", "None", "Some", "Ok", "Err"]
    static let kotlinKeywords: Set<String> = [
        "as", "break", "by", "class", "companion", "const", "continue", "data", "do", "else",
        "enum", "fun", "for", "if", "import", "in", "interface", "internal", "is", "lateinit",
        "object", "open", "override", "package", "private", "protected", "public", "return",
        "sealed", "suspend", "this", "throw", "try", "typealias", "val", "var", "when", "while"
    ]
    static let kotlinLiterals: Set<String> = ["true", "false", "null"]
    static let javaKeywords: Set<String> = [
        "abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default",
        "do", "else", "enum", "extends", "final", "finally", "for", "if", "implements", "import",
        "instanceof", "interface", "native", "new", "package", "private", "protected", "public",
        "return", "static", "strictfp", "super", "switch", "synchronized", "this", "throw",
        "throws", "transient", "try", "void", "volatile", "while"
    ]
    static let javaLiterals: Set<String> = ["true", "false", "null"]
    static let csharpKeywords: Set<String> = [
        "abstract", "as", "async", "await", "base", "break", "case", "catch", "class", "const",
        "continue", "default", "delegate", "do", "else", "enum", "event", "explicit", "extern",
        "finally", "fixed", "for", "foreach", "get", "goto", "if", "implicit", "in", "interface",
        "internal", "is", "lock", "namespace", "new", "operator", "out", "override", "params",
        "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "set",
        "sizeof", "stackalloc", "static", "struct", "switch", "this", "throw", "try", "typeof",
        "unsafe", "using", "var", "virtual", "void", "while", "yield"
    ]
    static let cKeywords: Set<String> = [
        "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern",
        "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static",
        "struct", "switch", "typedef", "union", "volatile", "while"
    ]
    static let cLiterals: Set<String> = ["true", "false", "NULL", "nullptr", "nil"]
    static let cppKeywords: Set<String> = cKeywords.union([
        "catch", "class", "constexpr", "delete", "explicit", "friend", "namespace", "new",
        "noexcept", "operator", "override", "private", "protected", "public", "template", "this",
        "throw", "try", "typename", "using", "virtual"
    ])
    static let objectiveCKeywords: Set<String> = cKeywords.union([
        "@class", "@end", "@implementation", "@interface", "@property", "@protocol", "@selector",
        "@synthesize", "id", "in", "self", "super"
    ])
    static let phpKeywords: Set<String> = [
        "abstract", "as", "break", "case", "catch", "class", "clone", "const", "continue",
        "declare", "default", "do", "echo", "else", "elseif", "enum", "extends", "final",
        "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include",
        "instanceof", "interface", "match", "namespace", "new", "print", "private", "protected",
        "public", "readonly", "require", "return", "static", "switch", "throw", "trait", "try",
        "use", "var", "while", "yield"
    ]
    static let phpLiterals: Set<String> = ["true", "false", "null", "TRUE", "FALSE", "NULL"]
    static let rubyKeywords: Set<String> = [
        "alias", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
        "end", "ensure", "for", "if", "in", "module", "next", "raise", "redo", "require",
        "require_relative", "rescue", "retry", "return", "self", "super", "then", "undef",
        "unless", "until", "when", "while", "yield"
    ]
    static let rubyLiterals: Set<String> = ["true", "false", "nil"]
    static let perlKeywords: Set<String> = [
        "do", "else", "elsif", "for", "foreach", "if", "last", "local", "my", "next", "our",
        "package", "redo", "require", "return", "sub", "unless", "until", "use", "while"
    ]
    static let luaKeywords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in",
        "local", "not", "or", "repeat", "return", "then", "until", "while"
    ]
    static let rKeywords: Set<String> = [
        "break", "else", "for", "function", "if", "in", "library", "next", "repeat", "require",
        "return", "while"
    ]
    static let rLiterals: Set<String> = ["TRUE", "FALSE", "NULL", "NA", "Inf", "NaN"]
    static let dartKeywords: Set<String> = [
        "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export",
        "extends", "extension", "external", "factory", "final", "finally", "for", "get", "if",
        "implements", "import", "in", "is", "late", "library", "mixin", "new", "on", "operator",
        "part", "required", "rethrow", "return", "sealed", "set", "static", "super", "switch",
        "sync", "this", "throw", "try", "typedef", "var", "void", "while", "with", "yield"
    ]
    static let scalaKeywords: Set<String> = [
        "abstract", "case", "catch", "class", "def", "do", "else", "extends", "final", "finally",
        "for", "given", "if", "implicit", "import", "lazy", "match", "new", "object", "override",
        "package", "private", "protected", "return", "sealed", "super", "this", "throw", "trait",
        "try", "type", "val", "var", "while", "with", "yield"
    ]
    static let groovyKeywords: Set<String> = javaKeywords.union([
        "def", "in", "it", "trait", "as"
    ])
    static let hclKeywords: Set<String> = [
        "data", "for", "for_each", "if", "locals", "module", "output", "provider", "resource",
        "terraform", "variable"
    ]
    static let protobufKeywords: Set<String> = [
        "bool", "bytes", "double", "enum", "extend", "float", "import", "int32", "int64", "map",
        "message", "oneof", "option", "package", "public", "repeated", "reserved", "returns",
        "rpc", "service", "string", "syntax", "uint32", "uint64"
    ]
    static let graphqlKeywords: Set<String> = [
        "enum", "extend", "fragment", "implements", "input", "interface", "mutation", "on",
        "query", "scalar", "schema", "subscription", "type", "union"
    ]
    static let powershellKeywords: Set<String> = [
        "BEGIN", "BREAK", "CATCH", "CLASS", "CONTINUE", "DO", "ELSE", "ELSEIF", "END", "ENUM",
        "FILTER", "FINALLY", "FOR", "FOREACH", "FUNCTION", "IF", "IN", "PARAM", "PROCESS",
        "RETURN", "SWITCH", "THROW", "TRY", "UNTIL", "USING", "WHILE"
    ]
    static let elixirKeywords: Set<String> = [
        "after", "alias", "case", "catch", "cond", "def", "defmacro", "defmodule", "defp",
        "defprotocol", "defstruct", "do", "else", "end", "fn", "for", "if", "import", "quote",
        "raise", "receive", "require", "rescue", "try", "unless", "unquote", "use", "when", "with"
    ]
    static let elixirLiterals: Set<String> = ["true", "false", "nil"]
    static let haskellKeywords: Set<String> = [
        "case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import",
        "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then",
        "type", "where"
    ]
}
