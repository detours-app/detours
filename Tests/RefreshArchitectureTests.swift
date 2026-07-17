import AppKit
import XCTest
@testable import Detours

/// T13 and the enforcement half of T15: a future code change cannot add a
/// second automatic list-update path without failing this suite. The source
/// scan rejects displayed-tree writes, outline mutation calls, authority
/// construction, and listing-affecting FileOperationQueue calls outside their
/// gateways; the runtime guard rejects direct outline mutation calls.
@MainActor
final class RefreshArchitectureTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("src")
    }

    private func swiftSources() throws -> [(path: String, contents: String)] {
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        var results: [(String, String)] = []
        while let next = enumerator?.nextObject() as? URL {
            guard next.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: next, encoding: .utf8)
            let relative = next.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            results.append((relative, contents))
        }
        XCTAssertGreaterThan(results.count, 50, "Source scan must see the app sources")
        return results
    }

    private func violations(
        matching pattern: String,
        allowedFiles: Set<String>,
        in sources: [(path: String, contents: String)]
    ) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for (path, contents) in sources {
            guard !allowedFiles.contains((path as NSString).lastPathComponent) else { continue }
            let lines = contents.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    found.append("\(path):\(index + 1): \(trimmed)")
                }
            }
        }
        return found
    }

    func testOnlyTheApplierExecutesOutlineMutations() throws {
        let sources = try swiftSources()
        // reload/insert/remove/move on the file-list outline. QuickLook's
        // panel.reloadData and NSMenu/FileManager removeItem/moveItem don't
        // match the receiver pattern.
        // SidebarViewController owns a separate outline; sidebar refresh
        // behavior is explicitly out of this spec's scope.
        let outlineCalls = try violations(
            matching: #"(outlineView|tableView)[?!]?\s*\.\s*(reloadData|reloadItem|insertItems|removeItems|moveItem)\s*\("#,
            allowedFiles: ["PaneOutlineApplier.swift", "BandedOutlineView.swift", "SidebarViewController.swift"],
            in: sources
        )
        XCTAssertEqual(
            outlineCalls, [],
            "Outline mutation calls outside PaneOutlineApplier:\n\(outlineCalls.joined(separator: "\n"))"
        )
    }

    func testOnlyTheApplierWritesDisplayedTreeState() throws {
        let sources = try swiftSources()
        let childWrites = try violations(
            matching: #"\.children\s*=\s*"#,
            allowedFiles: ["PaneOutlineApplier.swift", "FileItem.swift"],
            in: sources
        )
        XCTAssertEqual(
            childWrites, [],
            "FileItem.children writes outside the authority:\n\(childWrites.joined(separator: "\n"))"
        )

        let rootWrites = try violations(
            matching: #"\.items\s*=\s*|setDisplayedItems\("#,
            allowedFiles: ["PaneOutlineApplier.swift", "FileListDataSource.swift"],
            in: sources
        )
        XCTAssertEqual(
            rootWrites, [],
            "Displayed root writes outside the applier:\n\(rootWrites.joined(separator: "\n"))"
        )
    }

    func testOnlyTheApplierConstructsTheMutationAuthority() throws {
        let sources = try swiftSources()
        let constructions = try violations(
            matching: #"PaneOutlineMutationAuthority\s*\("#,
            allowedFiles: ["PaneOutlineApplier.swift"],
            in: sources
        )
        XCTAssertEqual(
            constructions, [],
            "Authority constructed outside PaneOutlineApplier:\n\(constructions.joined(separator: "\n"))"
        )
    }

    func testListingAffectingQueueCallsGoThroughTheCoordinator() throws {
        let sources = try swiftSources().filter { path, _ in
            // The queue's own implementation files and the operation-layer
            // plumbing reachable only through the coordinator are the
            // implementation surface, not entry points.
            let name = (path as NSString).lastPathComponent
            return !name.hasPrefix("FileOperationQueue")
                && name != "ClipboardManager.swift"
                && name != "LocalFileProvider.swift"
                && name != "PaneFileOperationCoordinator.swift"
        }
        var offenders: [String] = []
        for (path, contents) in sources {
            var searchRange = contents.startIndex..<contents.endIndex
            while let range = contents.range(
                of: #"FileOperationQueue\.shared\s*\.\s*(copy|move|delete|deleteImmediately|rename|duplicate|duplicateStructure|createFolder|createFile|archive|extract)\s*\("#,
                options: .regularExpression,
                range: searchRange
            ) {
                // The call is legal only when it executes inside a
                // coordinator transaction; require the wrapping call to
                // appear shortly before it in the same expression.
                let windowStart = contents.index(
                    range.lowerBound,
                    offsetBy: -600,
                    limitedBy: contents.startIndex
                ) ?? contents.startIndex
                let window = contents[windowStart..<range.lowerBound]
                if !window.contains("PaneFileOperationCoordinator.shared.perform") {
                    let prefix = contents[contents.startIndex..<range.lowerBound]
                    let line = prefix.components(separatedBy: "\n").count
                    offenders.append("\(path):\(line)")
                }
                searchRange = range.upperBound..<contents.endIndex
            }
        }
        XCTAssertEqual(
            offenders, [],
            "Listing-affecting queue calls outside a coordinator transaction:\n\(offenders.joined(separator: "\n"))"
        )
    }

    // MARK: - Runtime guard

    func testDirectOutlineMutationTripsTheGuard() {
        let outline = BandedOutlineView()
        let dataSource = FileListDataSource()
        dataSource.outlineView = outline
        outline.dataSource = dataSource
        outline.delegate = dataSource

        var reported: [String] = []
        let previousHandler = PaneOutlineGuard.violationHandler
        defer { PaneOutlineGuard.violationHandler = previousHandler }
        PaneOutlineGuard.violationHandler = { reported.append($0) }

        outline.reloadData()
        XCTAssertEqual(reported.count, 1, "A direct reloadData call must trip the guard")
        XCTAssertTrue(reported[0].contains("reloadData"))

        reported.removeAll()
        dataSource.applier.reloadAll()
        XCTAssertTrue(reported.isEmpty, "Applier-scoped mutations are authorized")
    }
}
