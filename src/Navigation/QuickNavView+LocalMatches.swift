import SwiftUI

extension QuickNavView {
    static func localMatches(
        for query: String,
        in roots: [URL],
        includeHidden: Bool,
        limit: Int
    ) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let tokens = query
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0).lowercased() }
            guard !tokens.isEmpty, !roots.isEmpty else { return [] }

            let fileManager = FileManager.default
            let maxDepth = 4
            let maxVisitedPerRoot = 5_000
            var seen = Set<String>()
            var matches: [(url: URL, isDirectory: Bool, depth: Int)] = []

            for root in roots {
                guard matches.count < limit else { break }

                let rootURL = root.standardizedFileURL
                var isRootDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isRootDirectory),
                      isRootDirectory.boolValue else {
                    continue
                }

                var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                if !includeHidden {
                    options.insert(.skipsHiddenFiles)
                }

                guard let enumerator = fileManager.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: options
                ) else {
                    continue
                }

                let rootDepth = rootURL.pathComponents.count
                var visited = 0

                while let candidate = enumerator.nextObject() as? URL {
                    if Task.isCancelled || matches.count >= limit || visited >= maxVisitedPerRoot {
                        break
                    }
                    visited += 1

                    let url = candidate.standardizedFileURL
                    let depth = max(0, url.pathComponents.count - rootDepth)
                    if depth > maxDepth {
                        enumerator.skipDescendants()
                        continue
                    }

                    if url.path.contains(".app/") ||
                        url.path.contains(".xcodeproj/") ||
                        url.path.contains(".xcworkspace/") ||
                        url.path.contains("node_modules/") ||
                        url.path.contains(".git/") {
                        enumerator.skipDescendants()
                        continue
                    }

                    let name = url.lastPathComponent.lowercased()
                    guard tokens.allSatisfy({ name.localizedCaseInsensitiveContains($0) }) else {
                        continue
                    }

                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                    let isDirectory = values?.isDirectory == true
                    guard seen.insert(url.path).inserted else { continue }
                    matches.append((url, isDirectory, depth))
                }
            }

            matches.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                if lhs.depth != rhs.depth {
                    return lhs.depth < rhs.depth
                }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }

            return matches.prefix(limit).map(\.url)
        }.value
    }
}
