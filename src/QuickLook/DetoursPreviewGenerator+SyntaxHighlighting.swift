import AppKit
import CryptoKit
import Foundation

extension DetoursPreviewGenerator {
    static func highlightSourceLine(_ raw: String, language: String) -> String {
        switch language {
        case "json":
            return highlightJSONLine(raw)
        case "yaml", "toml", "ini":
            return highlightConfigLine(raw)
        case "xml":
            return highlightXMLLine(raw)
        case "css":
            return highlightCSSLine(raw)
        case "diff":
            return highlightDiffLine(raw)
        case "markdown":
            return highlightMarkdownSourceLine(raw)
        default:
            guard let profile = languageProfiles[language] else {
                return escapeHTML(raw)
            }
            return highlightProgrammingLine(
                raw,
                commentMarker: profile.commentMarker,
                keywords: profile.keywords,
                literals: profile.literals,
                caseInsensitiveKeywords: profile.caseInsensitiveKeywords
            )
        }
    }

    private static func span(_ className: String, _ raw: String) -> String {
        "<span class=\"\(className)\">\(escapeHTML(raw))</span>"
    }

    private static func highlightJSONLine(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            if character == "\"" {
                let end = stringEnd(in: raw, from: index, quote: "\"")
                let token = String(raw[index..<end])
                let rest = raw[end...].trimmingCharacters(in: .whitespaces)
                output += span(rest.hasPrefix(":") ? "tok-property" : "tok-string", token)
                index = end
                continue
            }

            if character.isNumber || character == "-" {
                let end = raw[index...].firstIndex { char in
                    !(char.isNumber || char == "." || char == "-" || char == "+" || char == "e" || char == "E")
                } ?? raw.endIndex
                output += span("tok-number", String(raw[index..<end]))
                index = end
                continue
            }

            if let literal = matchingLiteral(in: raw, from: index, literals: commonLiterals) {
                output += span(literal == "null" ? "tok-null" : "tok-boolean", literal)
                index = raw.index(index, offsetBy: literal.count)
                continue
            }

            if "{}[]:,".contains(character) {
                output += span("tok-punctuation", String(character))
            } else {
                output += escapeHTML(String(character))
            }
            index = raw.index(after: index)
        }

        return output
    }

    private static func highlightProgrammingLine(
        _ raw: String,
        commentMarker: String,
        keywords: Set<String>,
        literals: Set<String>,
        caseInsensitiveKeywords: Bool = false
    ) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            if raw[index...].hasPrefix(commentMarker) {
                output += span("tok-comment", String(raw[index...]))
                break
            }

            let character = raw[index]
            if character == "\"" || character == "'" {
                let end = stringEnd(in: raw, from: index, quote: character)
                output += span("tok-string", String(raw[index..<end]))
                index = end
                continue
            }

            if character.isNumber {
                let end = raw[index...].firstIndex { char in
                    !(char.isNumber || char == "." || char == "_" || char == "x" || char == "X" ||
                      char == "b" || char == "B" || char == "e" || char == "E" || char.isHexDigit)
                } ?? raw.endIndex
                output += span("tok-number", String(raw[index..<end]))
                index = end
                continue
            }

            if isIdentifierStart(character) {
                let end = raw[index...].firstIndex { !isIdentifierPart($0) } ?? raw.endIndex
                let word = String(raw[index..<end])
                let lookup = caseInsensitiveKeywords ? word.uppercased() : word
                if keywords.contains(lookup) {
                    output += span("tok-keyword", word)
                } else if literals.contains(word) || literals.contains(word.lowercased()) {
                    output += span(word.lowercased() == "null" || word.lowercased() == "nil" ? "tok-null" : "tok-boolean", word)
                } else {
                    output += escapeHTML(word)
                }
                index = end
                continue
            }

            output += escapeHTML(String(character))
            index = raw.index(after: index)
        }

        return output
    }

    private static func highlightConfigLine(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
            return span("tok-comment", raw)
        }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return span("tok-section", raw)
        }

        let separator = raw.firstIndex { $0 == ":" || $0 == "=" }
        guard let separator else {
            return highlightProgrammingLine(raw, commentMarker: "#", keywords: [], literals: commonLiterals)
        }

        let key = String(raw[..<separator])
        let valueStart = raw.index(after: separator)
        let value = String(raw[valueStart...])
        return span("tok-property", key) +
            span("tok-punctuation", String(raw[separator])) +
            highlightProgrammingLine(value, commentMarker: "#", keywords: [], literals: commonLiterals)
    }

    private static func highlightXMLLine(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            guard raw[index] == "<", let close = raw[index...].firstIndex(of: ">") else {
                output += escapeHTML(String(raw[index]))
                index = raw.index(after: index)
                continue
            }

            let tag = String(raw[index...close])
            output += highlightXMLTag(tag)
            index = raw.index(after: close)
        }

        return output
    }

    private static func highlightXMLTag(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            if character == "<" || character == ">" || character == "/" || character == "=" {
                output += span("tok-punctuation", String(character))
                index = raw.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                let end = stringEnd(in: raw, from: index, quote: character)
                output += span("tok-string", String(raw[index..<end]))
                index = end
                continue
            }

            if isIdentifierStart(character) {
                let end = raw[index...].firstIndex { !(isIdentifierPart($0) || $0 == "-" || $0 == ":") } ?? raw.endIndex
                let token = String(raw[index..<end])
                let previous = raw[..<index].trimmingCharacters(in: .whitespaces)
                output += span(previous.hasSuffix("<") || previous.hasSuffix("</") ? "tok-tag" : "tok-attr", token)
                index = end
                continue
            }

            output += escapeHTML(String(character))
            index = raw.index(after: index)
        }

        return output
    }

    private static func highlightCSSLine(_ raw: String) -> String {
        if let commentStart = raw.range(of: "/*") {
            let before = String(raw[..<commentStart.lowerBound])
            let comment = String(raw[commentStart.lowerBound...])
            return highlightCSSLine(before) + span("tok-comment", comment)
        }

        if let colon = raw.firstIndex(of: ":") {
            let property = String(raw[..<colon])
            let value = String(raw[raw.index(after: colon)...])
            return span("tok-property", property) + span("tok-punctuation", ":") +
                highlightProgrammingLine(value, commentMarker: "/*", keywords: [], literals: commonLiterals)
        }

        return highlightProgrammingLine(raw, commentMarker: "/*", keywords: cssKeywords, literals: commonLiterals)
    }

    private static func highlightDiffLine(_ raw: String) -> String {
        if raw.hasPrefix("+") {
            return span("tok-add", raw)
        }
        if raw.hasPrefix("-") {
            return span("tok-delete", raw)
        }
        if raw.hasPrefix("@@") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
            return span("tok-section", raw)
        }
        return escapeHTML(raw)
    }

    private static func highlightMarkdownSourceLine(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            return span("tok-section", raw)
        }
        if trimmed.hasPrefix(">") {
            return span("tok-comment", raw)
        }
        return renderInlineSourceEmphasis(raw)
    }

    private static func renderInlineSourceEmphasis(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "`", let close = raw[raw.index(after: index)...].firstIndex(of: "`") {
                output += span("tok-string", String(raw[index...close]))
                index = raw.index(after: close)
                continue
            }
            output += escapeHTML(String(raw[index]))
            index = raw.index(after: index)
        }
        return output
    }

    private static func stringEnd(in raw: String, from start: String.Index, quote: Character) -> String.Index {
        var index = raw.index(after: start)
        var escaped = false
        while index < raw.endIndex {
            let character = raw[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return raw.index(after: index)
            }
            index = raw.index(after: index)
        }
        return raw.endIndex
    }

    private static func matchingLiteral(in raw: String, from index: String.Index, literals: Set<String>) -> String? {
        for literal in literals where raw[index...].hasPrefix(literal) {
            let end = raw.index(index, offsetBy: literal.count)
            if end == raw.endIndex || !isIdentifierPart(raw[end]) {
                return literal
            }
        }
        return nil
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private static let cssKeywords: Set<String> = [
        "display", "grid", "flex", "block", "none", "relative", "absolute", "fixed", "sticky",
        "var", "calc", "repeat", "minmax"
    ]
}
