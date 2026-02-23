import AppKit
import XCTest
@testable import Detours

@MainActor
final class StatusBarCountTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = try createTempDirectory()
    }

    override func tearDown() async throws {
        cleanupTempDirectory(tempDir)
        try await super.tearDown()
    }

    /// Creates a FileListViewController with items loaded synchronously (bypasses async DirectoryLoader).
    private func makeViewController(
        rootItems: [FileItem]
    ) -> (FileListViewController, FileListDataSource) {
        let vc = FileListViewController()
        vc.loadViewIfNeeded()

        let ds = vc.dataSource
        ds.items = rootItems
        vc.tableView.reloadData()

        return (vc, ds)
    }

    private func makeFile(name: String, size: Int64 = 0) -> FileItem {
        let url = tempDir.appendingPathComponent(name)
        return FileItem(
            name: name, url: url, isDirectory: false,
            size: size, dateModified: Date(), icon: NSImage()
        )
    }

    private func makeFolder(name: String, children: [FileItem]) -> FileItem {
        let url = tempDir.appendingPathComponent(name)
        let folder = FileItem(
            name: name, url: url, isDirectory: true,
            size: nil, dateModified: Date(), icon: NSImage()
        )
        folder.children = children
        return folder
    }

    // MARK: - Item count matches outline view rows

    func testItemCountMatchesOutlineViewRows() {
        let folder = makeFolder(name: "Folder", children: [
            makeFile(name: "child1.txt"),
            makeFile(name: "child2.txt"),
        ])
        let (vc, ds) = makeViewController(rootItems: [
            makeFile(name: "a.txt"),
            makeFile(name: "b.txt"),
            folder,
        ])

        // Without expansion: numberOfRows == root items count
        XCTAssertEqual(vc.tableView.numberOfRows, 3, "Should show 3 root items")

        // Expand the folder
        vc.tableView.expandItem(folder)

        // After expansion: numberOfRows includes children
        XCTAssertEqual(vc.tableView.numberOfRows, 5, "Should show 3 root + 2 children = 5 rows")

        // items.count remains at root level — this was the old (buggy) source for status bar
        XCTAssertEqual(ds.items.count, 3, "Root items array should still be 3")
        XCTAssertNotEqual(ds.items.count, vc.tableView.numberOfRows,
            "items.count must differ from numberOfRows when folders are expanded")
    }

    // MARK: - Selected count never exceeds item count

    func testSelectedCountNeverExceedsItemCount() {
        let folder = makeFolder(name: "Folder", children: [
            makeFile(name: "child1.txt"),
            makeFile(name: "child2.txt"),
            makeFile(name: "child3.txt"),
        ])
        let (vc, _) = makeViewController(rootItems: [
            makeFile(name: "a.txt"),
            makeFile(name: "b.txt"),
            folder,
        ])

        vc.tableView.expandItem(folder)

        let totalRows = vc.tableView.numberOfRows
        XCTAssertEqual(totalRows, 6, "3 root + 3 children = 6")

        // Select all rows
        vc.tableView.selectRowIndexes(IndexSet(integersIn: 0..<totalRows), byExtendingSelection: false)
        let selectedCount = vc.tableView.selectedRowIndexes.count

        XCTAssertLessThanOrEqual(selectedCount, totalRows,
            "Selected count should never exceed total visible row count")
    }

    // MARK: - Filtered item count reflects filter

    func testFilteredItemCountReflectsFilter() {
        let (vc, ds) = makeViewController(rootItems: [
            makeFile(name: "apple.txt"),
            makeFile(name: "banana.txt"),
            makeFile(name: "cherry.txt"),
        ])

        XCTAssertEqual(vc.tableView.numberOfRows, 3, "Should show 3 items before filter")

        // Apply filter
        ds.filterPredicate = "apple"
        vc.tableView.reloadData()

        XCTAssertEqual(vc.tableView.numberOfRows, 1, "Should show 1 item after filter")
        XCTAssertEqual(ds.totalItemCount, 3, "totalItemCount should be unfiltered root count")
    }

    // MARK: - Selection size uses correct items via item(at:)

    func testSelectionSizeUsesCorrectItems() {
        let childFile = makeFile(name: "b.txt", size: 200)
        let folder = makeFolder(name: "Folder", children: [childFile])
        let rootFile = makeFile(name: "a.txt", size: 100)

        let (vc, ds) = makeViewController(rootItems: [folder, rootFile])

        // Expand folder
        vc.tableView.expandItem(folder)

        let totalRows = vc.tableView.numberOfRows
        XCTAssertEqual(totalRows, 3, "Should have folder + child + file = 3 rows")

        // Verify item(at:) returns valid items for every row
        for row in 0..<totalRows {
            XCTAssertNotNil(ds.item(at: row), "item(at: \(row)) should return a valid FileItem")
        }

        // Find the child file's row
        var childRow = -1
        for row in 0..<totalRows {
            if ds.item(at: row)?.name == "b.txt" {
                childRow = row
                break
            }
        }
        XCTAssertNotEqual(childRow, -1, "Should find b.txt in the outline view")

        // item(at:) must return the actual child item, not a root item by array index
        let resolved = ds.item(at: childRow)
        XCTAssertEqual(resolved?.name, "b.txt")
        XCTAssertEqual(resolved?.size, 200, "Should have the correct file size")
    }

    // MARK: - totalVisibleItemCount respects filter with expanded children

    func testTotalVisibleItemCountRespectsFilter() {
        let folder = makeFolder(name: "Folder", children: [
            makeFile(name: "cherry.txt"),
        ])
        let (vc, ds) = makeViewController(rootItems: [
            makeFile(name: "apple.txt"),
            makeFile(name: "banana.txt"),
            folder,
        ])

        // Expand folder
        vc.tableView.expandItem(folder)

        let visibleBeforeFilter = ds.totalVisibleItemCount
        XCTAssertEqual(visibleBeforeFilter, 4, "Should count 3 root + 1 child = 4 visible items")

        // Filter that matches only "apple"
        ds.filterPredicate = "apple"
        vc.tableView.reloadData()

        let visibleAfterFilter = ds.totalVisibleItemCount
        XCTAssertEqual(visibleAfterFilter, 1, "Should count only 1 filtered visible item")
    }
}
