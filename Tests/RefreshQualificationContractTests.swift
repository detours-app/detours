import AppKit
import XCTest
@testable import Detours

/// Fast, deterministic refresh qualification. The cases are fixed and explicit:
/// high repetition belongs here, while filesystem/provider and XCUI tests prove
/// only their unique boundaries.
@MainActor
final class RefreshQualificationContractTests: XCTestCase {
    private enum Change {
        case create
        case delete
        case rename
        case metadata
        case noop
    }

    private struct Case {
        let name: String
        let ascending: Bool
        let filter: String?
        let showsHidden: Bool
        let change: Change
        let selection: String
        let expectedNames: [String]
        let expectedNoop: Bool
        let selectionSurvives: Bool
    }

    private let rootURL = URL(fileURLWithPath: "/detours-refresh-contract")
    private var root: Location { .local(rootURL) }

    func testExplicitPairwiseRefreshCases() throws {
        let cases = [
            Case(
                name: "ascending create with visible hidden item",
                ascending: true,
                filter: nil,
                showsHidden: true,
                change: .create,
                selection: "alpha.txt",
                expectedNames: ["Folder", "alpha.txt", "beta.txt", "gamma.txt", "hidden.txt"],
                expectedNoop: false,
                selectionSurvives: true
            ),
            Case(
                name: "descending create with concealed hidden item",
                ascending: false,
                filter: nil,
                showsHidden: false,
                change: .create,
                selection: "beta.txt",
                expectedNames: ["Folder", "gamma.txt", "beta.txt", "alpha.txt"],
                expectedNoop: false,
                selectionSurvives: true
            ),
            Case(
                name: "ascending delete through matching filter",
                ascending: true,
                filter: "alpha",
                showsHidden: false,
                change: .delete,
                selection: "beta.txt",
                expectedNames: ["Folder", "alpha.txt"],
                expectedNoop: false,
                selectionSurvives: false
            ),
            Case(
                name: "descending rename through excluding filter",
                ascending: false,
                filter: "delta",
                showsHidden: true,
                change: .rename,
                selection: "beta.txt",
                expectedNames: ["delta.txt"],
                expectedNoop: false,
                selectionSurvives: false
            ),
            Case(
                name: "ascending metadata change preserves selected identity",
                ascending: true,
                filter: nil,
                showsHidden: false,
                change: .metadata,
                selection: "alpha.txt",
                expectedNames: ["Folder", "alpha.txt", "beta.txt"],
                expectedNoop: false,
                selectionSurvives: true
            ),
            Case(
                name: "descending no-op remains descending",
                ascending: false,
                filter: nil,
                showsHidden: false,
                change: .noop,
                selection: "alpha.txt",
                expectedNames: ["Folder", "beta.txt", "alpha.txt"],
                expectedNoop: true,
                selectionSurvives: true
            ),
            Case(
                name: "ascending filtered no-op keeps descendant match",
                ascending: true,
                filter: "nested",
                showsHidden: true,
                change: .noop,
                selection: "beta.txt",
                expectedNames: ["Folder"],
                expectedNoop: true,
                selectionSurvives: true
            ),
            Case(
                name: "descending hidden metadata change stays filtered",
                ascending: false,
                filter: "hidden",
                showsHidden: true,
                change: .metadata,
                selection: "hidden.txt",
                expectedNames: ["hidden.txt"],
                expectedNoop: false,
                selectionSurvives: true
            ),
        ]

        for testCase in cases {
            try XCTContext.runActivity(named: testCase.name) { _ in
                let dataSource = FileListDataSource()
                dataSource.displayedRootLocation = root
                dataSource.sortDescriptor = SortDescriptor(column: .name, ascending: testCase.ascending)
                dataSource.filterPredicate = testCase.filter
                dataSource.showHiddenFiles = testCase.showsHidden

                let initialEntries = baseEntries(showsHidden: testCase.showsHidden)
                let initialItems = initialEntries.map { dataSource.makeFileItem(from: $0) }
                let folder = try XCTUnwrap(initialItems.first { $0.name == "Folder" })
                let nested = item(name: "alpha-nested.txt", parent: folder.location)
                folder.setChildrenForTesting([nested])
                nested.parent = folder
                dataSource.applier.setRootItems(
                    FileItem.sorted(initialItems, by: dataSource.sortDescriptor, foldersOnTop: true)
                )
                let selected = try XCTUnwrap(dataSource.items.first { $0.name == testCase.selection })

                let reconciliation = try XCTUnwrap(
                    dataSource.reconcileListingEntries(
                        changedEntries(
                            from: initialEntries,
                            change: testCase.change,
                            metadataTarget: testCase.selection
                        ),
                        in: root
                    )
                )

                XCTAssertEqual(dataSource.visibleItems.map(\.name), testCase.expectedNames)
                XCTAssertEqual(reconciliation.isNoop, testCase.expectedNoop)
                XCTAssertEqual(
                    reconciliation.reconciledItems.contains { $0 === selected },
                    testCase.selectionSurvives
                )
                XCTAssertTrue(
                    reconciliation.reconciledItems.first { $0.name == "Folder" }?.children?.first === nested,
                    "Loaded expansion identity must survive root reconciliation"
                )
            }
        }
    }

    func testKnownDefectReplayUsesProductionPolicies() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            LoadedFileEntry.stableModificationDate(resourceDate: nil, fileAttributeDate: fixedDate),
            fixedDate,
            "Missing SMB resource metadata must use the stable stat timestamp"
        )
        XCTAssertEqual(
            LoadedFileEntry.stableModificationDate(resourceDate: nil, fileAttributeDate: nil),
            .distantPast,
            "Missing timestamps must not invent the current time"
        )

        let original = item(name: "jitter.txt", date: fixedDate)
        let jittered = item(name: "jitter.txt", date: fixedDate.addingTimeInterval(0.0085))
        XCTAssertFalse(
            original.updateListingMetadata(from: jittered, isNetworkVolume: true),
            "Sub-tolerance SMB timestamp jitter must not redraw"
        )

        let dataSource = FileListDataSource()
        dataSource.displayedRootLocation = root
        dataSource.sortDescriptor = SortDescriptor(column: .name, ascending: false)
        let entries = baseEntries(showsHidden: false)
        let items = entries.map { dataSource.makeFileItem(from: $0) }
        dataSource.applier.setRootItems(
            FileItem.sorted(items, by: dataSource.sortDescriptor, foldersOnTop: true)
        )
        let reconciliation = try XCTUnwrap(dataSource.reconcileListingEntries(entries, in: root))
        XCTAssertEqual(reconciliation.reconciledItems.map(\.name), ["Folder", "beta.txt", "alpha.txt"])
        XCTAssertTrue(reconciliation.isNoop, "An unchanged refresh must not mutate the listing")
    }

    private func baseEntries(showsHidden: Bool) -> [LoadedFileEntry] {
        var entries = [
            entry(name: "Folder", isDirectory: true),
            entry(name: "alpha.txt"),
            entry(name: "beta.txt"),
        ]
        if showsHidden {
            entries.append(entry(name: "hidden.txt", isHidden: true))
        }
        return entries
    }

    private func changedEntries(
        from entries: [LoadedFileEntry],
        change: Change,
        metadataTarget: String
    ) -> [LoadedFileEntry] {
        switch change {
        case .create:
            return entries + [entry(name: "gamma.txt")]
        case .delete:
            return entries.filter { $0.name != "beta.txt" }
        case .rename:
            return entries.filter { $0.name != "beta.txt" } + [entry(name: "delta.txt")]
        case .metadata:
            return entries.map { current in
                current.name == metadataTarget
                    ? entry(name: current.name, isHidden: current.isHidden, size: 99)
                    : current
            }
        case .noop:
            return entries
        }
    }

    private func entry(
        name: String,
        isDirectory: Bool = false,
        isHidden: Bool = false,
        size: Int64 = 1
    ) -> LoadedFileEntry {
        let url = rootURL.appendingPathComponent(name, isDirectory: isDirectory)
        return LoadedFileEntry(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isHidden: isHidden,
            fileSize: isDirectory ? nil : size,
            contentModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func item(
        name: String,
        parent: Location? = nil,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FileItem {
        let location = parent?.appendingPathComponent(name) ?? root.appendingPathComponent(name)
        return FileItem(
            name: name,
            location: location,
            isDirectory: false,
            size: 1,
            dateModified: date,
            icon: NSImage(size: NSSize(width: 1, height: 1))
        )
    }
}
