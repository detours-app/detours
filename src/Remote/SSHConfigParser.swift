import Foundation

struct SSHConfigParser {
    func hostSuggestions(from config: String) -> [String] {
        var suggestions: [String] = []
        var seen: Set<String> = []
        var insideMatchBlock = false

        for rawLine in config.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let isTopLevel = rawLine == rawLine.trimmingCharacters(in: .whitespaces)

            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = parts.first?.lowercased() else { continue }

            switch keyword {
            case "match":
                if isTopLevel {
                    insideMatchBlock = true
                }
            case "host":
                guard isTopLevel else { continue }
                insideMatchBlock = false
                for pattern in parts.dropFirst() where isSuggestableHostPattern(pattern) {
                    if seen.insert(pattern).inserted {
                        suggestions.append(pattern)
                    }
                }
            case "include":
                continue
            default:
                if insideMatchBlock {
                    continue
                }
            }
        }

        return suggestions
    }

    func hostSuggestions(fromConfigAt url: URL) -> [String] {
        guard let config = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return hostSuggestions(from: config)
    }

    private func isSuggestableHostPattern(_ pattern: String) -> Bool {
        !pattern.isEmpty && pattern != "*" && !pattern.hasPrefix("!")
    }
}
