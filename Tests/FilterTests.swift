import XCTest
@testable import Detours

@MainActor
final class FilterTests: XCTestCase {
    var tempDir: URL!
    var dataSource: FileListDataSource!

    override func setUp() async throws {
        try await super.setUp()

        // Create temp directory with test files
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create test files
        let files = [
            "Document.txt",
            "document.pdf",
            "README.md",
            "image.png",
            "MyDocument.docx",
        ]
        for file in files {
            try "".write(to: tempDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        // Create a folder with children
        let folder = tempDir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "".write(to: folder.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        dataSource = FileListDataSource()
        dataSource.loadDirectory(tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testFilterMatchesSubstring() {
        // "doc" should match "Document.txt", "document.pdf", "MyDocument.docx", and "Documents" folder
        dataSource.filterPredicate = "doc"
        let visible = dataSource.visibleItems

        let names = visible.map { $0.name }
        XCTAssertTrue(names.contains("Document.txt"))
        XCTAssertTrue(names.contains("document.pdf"))
        XCTAssertTrue(names.contains("MyDocument.docx"))
        XCTAssertTrue(names.contains("Documents"))
        XCTAssertFalse(names.contains("README.md"))
        XCTAssertFalse(names.contains("image.png"))
    }

    func testFilterCaseInsensitive() {
        // "DOC" should match "document.pdf" (case-insensitive)
        dataSource.filterPredicate = "DOC"
        let visible = dataSource.visibleItems

        let names = visible.map { $0.name }
        XCTAssertTrue(names.contains("document.pdf"))
        XCTAssertTrue(names.contains("Document.txt"))
    }

    func testFilterNoMatch() {
        // "xyz" should return empty
        dataSource.filterPredicate = "xyz"
        let visible = dataSource.visibleItems

        XCTAssertTrue(visible.isEmpty)
    }

    func testFilterPreservesExpansion() throws {
        // This test verifies that when a folder matches the filter,
        // expansion state is preserved
        let folder = dataSource.visibleItems.first { $0.name == "Documents" }
        XCTAssertNotNil(folder)

        // Load children and expand
        _ = folder!.loadChildren(showHidden: false)
        XCTAssertNotNil(folder!.children)

        // Filter to match the folder
        dataSource.filterPredicate = "doc"
        let visible = dataSource.visibleItems

        // Folder should still be visible and have children loaded
        let filteredFolder = visible.first { $0.name == "Documents" }
        XCTAssertNotNil(filteredFolder)
        XCTAssertNotNil(filteredFolder?.children)
    }

    func testClearFilterRestoresFullList() {
        let originalCount = dataSource.visibleItems.count

        // Apply filter
        dataSource.filterPredicate = "doc"
        XCTAssertLessThan(dataSource.visibleItems.count, originalCount)

        // Clear filter
        dataSource.filterPredicate = nil
        XCTAssertEqual(dataSource.visibleItems.count, originalCount)
    }

    func testTotalItemCountUnaffectedByFilter() {
        let totalBefore = dataSource.totalItemCount

        dataSource.filterPredicate = "doc"

        // Total count should remain the same even when filtered
        XCTAssertEqual(dataSource.totalItemCount, totalBefore)
        // But visible count should be different
        XCTAssertLessThan(dataSource.visibleItems.count, totalBefore)
    }

    func testFilterMatchesNestedFileRecursively() throws {
        // Create nested structure: Grandparent/Parent/darnuzer_target.txt
        let grandparent = tempDir.appendingPathComponent("Grandparent")
        let parent = grandparent.appendingPathComponent("Parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try "".write(to: parent.appendingPathComponent("darnuzer_target.txt"), atomically: true, encoding: .utf8)
        try "".write(to: parent.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try "".write(to: grandparent.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)

        // Reload to pick up new structure
        dataSource.loadDirectory(tempDir)

        // Find and expand Grandparent folder
        let grandparentItem = dataSource.visibleItems.first { $0.name == "Grandparent" }
        XCTAssertNotNil(grandparentItem, "Grandparent folder should exist")
        _ = grandparentItem!.loadChildren(showHidden: false)

        // Find and expand Parent folder
        let parentItem = grandparentItem!.children?.first { $0.name == "Parent" }
        XCTAssertNotNil(parentItem, "Parent folder should exist")
        _ = parentItem!.loadChildren(showHidden: false)

        // Now filter for "darnuzer"
        dataSource.filterPredicate = "darnuzer"

        // Grandparent should be visible (descendant matches)
        let filteredGrandparent = dataSource.visibleItems.first { $0.name == "Grandparent" }
        XCTAssertNotNil(filteredGrandparent, "Grandparent should be visible because descendant matches 'darnuzer'")

        // Use data source's filteredChildren to get filtered children (simulating outline view)
        let grandparentChildren = dataSource.filteredChildren(of: filteredGrandparent!) ?? []

        // Grandparent's filtered children should include Parent (because Parent has matching descendant)
        let filteredParent = grandparentChildren.first { $0.name == "Parent" }
        XCTAssertNotNil(filteredParent, "Parent should be visible because child matches 'darnuzer'")

        // sibling.txt in Grandparent should NOT be visible
        let siblingFile = grandparentChildren.first { $0.name == "sibling.txt" }
        XCTAssertNil(siblingFile, "sibling.txt should NOT be visible (doesn't match filter)")

        // Parent's filtered children should include only darnuzer_target.txt, not other.txt
        let parentChildren = dataSource.filteredChildren(of: filteredParent!) ?? []
        let targetFile = parentChildren.first { $0.name == "darnuzer_target.txt" }
        XCTAssertNotNil(targetFile, "darnuzer_target.txt should be visible")

        let otherFile = parentChildren.first { $0.name == "other.txt" }
        XCTAssertNil(otherFile, "other.txt should NOT be visible (doesn't match filter)")
    }
}
