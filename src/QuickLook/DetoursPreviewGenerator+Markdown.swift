import AppKit
import CryptoKit
import Foundation

extension DetoursPreviewGenerator {
    static func renderStaticMarkdown(_ source: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var listKind: String?
        var inFence = false
        var fenceLanguage = "plaintext"
        var fenceLines: [String] = []

        func closeParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(renderInlineMarkdown(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        func closeList() {
            guard let current = listKind else { return }
            html.append("</\(current)>")
            listKind = nil
        }

        func closeFence() {
            guard inFence else { return }
            if isTrustedHTMLFenceLanguage(fenceLanguage),
               let severityBarHTML = sanitizedSeverityBarHTML(from: fenceLines) {
                html.append(severityBarHTML)
            } else {
                let highlightedFence = fenceLines
                    .map { highlightSourceLine($0, language: fenceLanguage) }
                    .joined(separator: "\n")
                html.append(
                    """
                    <pre><code class="language-\(escapeHTML(fenceLanguage))" data-highlight-language="\(escapeHTML(fenceLanguage))" data-static-highlight="true">\(highlightedFence)</code></pre>
                    """
                )
            }
            inFence = false
            fenceLanguage = "plaintext"
            fenceLines.removeAll()
        }

        let sourceLines = source.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < sourceLines.count {
            let rawLine = sourceLines[lineIndex]
            lineIndex += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if inFence {
                    closeFence()
                } else {
                    closeParagraph()
                    closeList()
                    inFence = true
                    let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    fenceLanguage = language.isEmpty ? "plaintext" : language
                }
                continue
            }

            if inFence {
                fenceLines.append(rawLine)
                continue
            }

            if let severityBar = trustedSeverityBarBlock(in: sourceLines, startingAt: lineIndex - 1) {
                closeParagraph()
                closeList()
                html.append(severityBar.html)
                lineIndex = severityBar.nextIndex
                continue
            }

            if line.isEmpty {
                closeParagraph()
                closeList()
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                closeParagraph()
                closeList()
                html.append("<hr>")
                continue
            }

            if let heading = headingParts(from: line) {
                closeParagraph()
                closeList()
                html.append("<h\(heading.level)>\(renderInlineMarkdown(heading.text))</h\(heading.level)>")
                continue
            }

            if let item = unorderedListItem(from: line) {
                closeParagraph()
                if listKind != "ul" {
                    closeList()
                    html.append("<ul>")
                    listKind = "ul"
                }
                html.append("<li>\(renderInlineMarkdown(item))</li>")
                continue
            }

            if let item = orderedListItem(from: line) {
                closeParagraph()
                if listKind != "ol" {
                    closeList()
                    html.append("<ol>")
                    listKind = "ol"
                }
                html.append("<li>\(renderInlineMarkdown(item))</li>")
                continue
            }

            closeList()
            if line.hasPrefix(">") {
                closeParagraph()
                let quote = line.dropFirst().trimmingCharacters(in: .whitespaces)
                html.append("<blockquote>\(renderInlineMarkdown(quote))</blockquote>")
                continue
            }

            paragraph.append(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        closeFence()
        closeParagraph()
        closeList()
        return html.joined(separator: "\n")
    }

    private static func isTrustedHTMLFenceLanguage(_ language: String) -> Bool {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "{=html}"
    }

    private static func trustedSeverityBarBlock(
        in lines: [String],
        startingAt startIndex: Int
    ) -> (html: String, nextIndex: Int)? {
        guard startIndex < lines.count,
              lines[startIndex].trimmingCharacters(in: .whitespaces) == "<div class=\"sevbar\">" else {
            return nil
        }

        var blockLines = [lines[startIndex]]
        var index = startIndex + 1
        while index < lines.count, blockLines.count < 16 {
            blockLines.append(lines[index])
            if lines[index].trimmingCharacters(in: .whitespaces) == "</div>" {
                guard let html = sanitizedSeverityBarHTML(from: blockLines) else {
                    return nil
                }
                return (html, index + 1)
            }
            index += 1
        }
        return nil
    }

    private static func sanitizedSeverityBarHTML(from lines: [String]) -> String? {
        guard lines.count >= 3,
              lines.first?.trimmingCharacters(in: .whitespaces) == "<div class=\"sevbar\">",
              lines.last?.trimmingCharacters(in: .whitespaces) == "</div>" else {
            return nil
        }

        let allowedSeverityClasses = Set(["c-critical", "c-high", "c-medium", "c-low"])
        let cellPattern = #"^\s*<div\s+class="cell\s+(c-[a-z]+)">\s*<span\s+class="n">([^<>]{1,32})</span>\s*<span\s+class="l">([^<>]{1,64})</span>\s*</div>\s*$"#
        guard let cellExpression = try? NSRegularExpression(pattern: cellPattern) else {
            return nil
        }

        var cells: [String] = []
        for rawLine in lines.dropFirst().dropLast() {
            let fullRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard let match = cellExpression.firstMatch(in: rawLine, range: fullRange),
                  match.range == fullRange,
                  let severityRange = Range(match.range(at: 1), in: rawLine),
                  let countRange = Range(match.range(at: 2), in: rawLine),
                  let labelRange = Range(match.range(at: 3), in: rawLine) else {
                return nil
            }

            let severityClass = String(rawLine[severityRange])
            guard allowedSeverityClasses.contains(severityClass) else {
                return nil
            }

            let count = escapeHTML(String(rawLine[countRange]).trimmingCharacters(in: .whitespacesAndNewlines))
            let label = escapeHTML(String(rawLine[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines))
            guard !count.isEmpty, !label.isEmpty else {
                return nil
            }

            cells.append(
                """
                  <div class="cell \(severityClass)"><span class="n">\(count)</span><span class="l">\(label)</span></div>
                """
            )
        }

        guard !cells.isEmpty else {
            return nil
        }

        return """
        <div class="sevbar">
        \(cells.joined(separator: "\n"))
        </div>
        """
    }

    private static func headingParts(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else {
            return nil
        }
        return (hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedListItem(from line: String) -> String? {
        guard line.count > 2 else { return nil }
        let marker = line.prefix(2)
        guard marker == "- " || marker == "* " || marker == "+ " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedListItem(from line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    private static func renderInlineMarkdown(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            if raw[index] == "!", raw.index(after: index) < raw.endIndex, raw[raw.index(after: index)] == "[",
               let parsed = parseMarkdownLink(in: raw, from: raw.index(after: index)) {
                let alt = parsed.text.isEmpty ? "image" : parsed.text
                output += "<span class=\"blocked-image\">Image blocked: \(escapeHTML(alt))</span>"
                index = parsed.endIndex
                continue
            }

            if raw[index] == "[", let parsed = parseMarkdownLink(in: raw, from: index) {
                output += "<span class=\"inert-link\">\(escapeHTML(parsed.text))</span>"
                index = parsed.endIndex
                continue
            }

            if raw[index] == "`", let closing = raw[raw.index(after: index)...].firstIndex(of: "`") {
                let codeStart = raw.index(after: index)
                output += "<code>\(escapeHTML(String(raw[codeStart..<closing])))</code>"
                index = raw.index(after: closing)
                continue
            }

            if let parsed = parseDelimitedInline(in: raw, from: index, delimiter: "**", tag: "strong") ??
                parseDelimitedInline(in: raw, from: index, delimiter: "__", tag: "strong") ??
                parseDelimitedInline(in: raw, from: index, delimiter: "*", tag: "em") ??
                parseDelimitedInline(in: raw, from: index, delimiter: "_", tag: "em") {
                output += parsed.html
                index = parsed.endIndex
                continue
            }

            output += escapeHTML(String(raw[index]))
            index = raw.index(after: index)
        }

        return output
    }

    private static func parseMarkdownLink(in raw: String, from openBracket: String.Index) -> (text: String, endIndex: String.Index)? {
        guard raw[openBracket] == "[",
              let closeBracket = raw[raw.index(after: openBracket)...].firstIndex(of: "]") else {
            return nil
        }
        let openParen = raw.index(after: closeBracket)
        guard openParen < raw.endIndex, raw[openParen] == "(",
              let closeParen = raw[raw.index(after: openParen)...].firstIndex(of: ")") else {
            return nil
        }
        return (String(raw[raw.index(after: openBracket)..<closeBracket]), raw.index(after: closeParen))
    }

    private static func parseDelimitedInline(
        in raw: String,
        from index: String.Index,
        delimiter: String,
        tag: String
    ) -> (html: String, endIndex: String.Index)? {
        guard raw[index...].hasPrefix(delimiter) else {
            return nil
        }

        let contentStart = raw.index(index, offsetBy: delimiter.count)
        guard contentStart < raw.endIndex,
              let contentEnd = raw[contentStart...].range(of: delimiter)?.lowerBound,
              contentEnd > contentStart else {
            return nil
        }

        let content = String(raw[contentStart..<contentEnd])
        let rendered = renderInlineMarkdown(content)
        return ("<\(tag)>\(rendered)</\(tag)>", raw.index(contentEnd, offsetBy: delimiter.count))
    }
}
