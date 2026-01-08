import XCTest
@testable import Detours

final class SystemIntegrationTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Context Menu Tests

    @MainActor
    func testContextMenuBuildsForFile() async throws {
        // Create a test file
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello".write(to: testFile, atomically: true, encoding: .utf8)

        let vc = FileListViewController()
        vc.loadView()
        vc.viewDidLoad()
        vc.loadDirectory(tempDir)

        // Select the file
        vc.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        // Build context menu
        let menu = vc.buildContextMenu(for: IndexSet(integer: 0), clickedRow: 0)

        XCTAssertNotNil(menu, "Context menu should be created")

        // Check expected items exist
        let titles = menu?.items.map { $0.title } ?? []
        XCTAssertTrue(titles.contains("Open"), "Menu should have Open item")
        XCTAssertTrue(titles.contains("Open With"), "Menu should have Open With item for file")
        XCTAssertTrue(titles.contains("Copy"), "Menu should have Copy item")
        XCTAssertTrue(titles.contains("Cut"), "Menu should have Cut item")
        XCTAssertTrue(titles.contains("Paste"), "Menu should have Paste item")
        XCTAssertTrue(titles.contains("Move to Trash"), "Menu should have Move to Trash item")
        XCTAssertTrue(titles.contains("Rename"), "Menu should have Rename item for single selection")
        XCTAssertTrue(titles.contains("Get Info"), "Menu should have Get Info item")
        XCTAssertTrue(titles.contains("Copy Path"), "Menu should have Copy Path item")
        XCTAssertTrue(titles.contains("New Folder"), "Menu should have New Folder item")
        XCTAssertTrue(titles.contains("Services"), "Menu should have Services item")
    }

    @MainActor
    func testContextMenuBuildsForFolder() async throws {
        // Create a test folder
        let testFolder = tempDir.appendingPathComponent("TestFolder")
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)

        let vc = FileListViewController()
        vc.loadView()
        vc.viewDidLoad()
        vc.loadDirectory(tempDir)

        // Select the folder
        vc.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        // Build context menu
        let menu = vc.buildContextMenu(for: IndexSet(integer: 0), clickedRow: 0)

        XCTAssertNotNil(menu, "Context menu should be created")

        let titles = menu?.items.map { $0.title } ?? []
        XCTAssertTrue(titles.contains("Open"), "Menu should have Open item")
        // Open With should not appear for folders
        XCTAssertFalse(titles.contains("Open With"), "Menu should NOT have Open With item for folder")
    }

    @MainActor
    func testContextMenuBuildsForMultipleSelection() async throws {
        // Create test files
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        try "A".write(to: file1, atomically: true, encoding: .utf8)
        try "B".write(to: file2, atomically: true, encoding: .utf8)

        let vc = FileListViewController()
        vc.loadView()
        vc.viewDidLoad()
        vc.loadDirectory(tempDir)

        // Select both files
        let selection = IndexSet([0, 1])
        vc.tableView.selectRowIndexes(selection, byExtendingSelection: false)

        // Build context menu
        let menu = vc.buildContextMenu(for: selection, clickedRow: 0)

        XCTAssertNotNil(menu, "Context menu should be created")

        let titles = menu?.items.map { $0.title } ?? []
        XCTAssertTrue(titles.contains("Open"), "Menu should have Open item")
        XCTAssertTrue(titles.contains("Copy"), "Menu should have Copy item")
        XCTAssertTrue(titles.contains("Move to Trash"), "Menu should have Move to Trash item")
        // Rename should not appear for multiple selection
        XCTAssertFalse(titles.contains("Rename"), "Menu should NOT have Rename item for multi-selection")
        // Open With should not appear for multiple files
        XCTAssertFalse(titles.contains("Open With"), "Menu should NOT have Open With item for multi-selection")
    }

    // MARK: - Open With Tests

    @MainActor
    func testOpenWithAppsForTextFile() async throws {
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello".write(to: testFile, atomically: true, encoding: .utf8)

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: testFile)

        // Should have at least one app that can open .txt files (TextEdit at minimum)
        XCTAssertFalse(apps.isEmpty, "Should have apps available to open .txt files")
    }

    @MainActor
    func testOpenWithAppsForImage() async throws {
        // Create a minimal PNG file
        let testFile = tempDir.appendingPathComponent("test.png")

        // Minimal valid PNG (1x1 transparent pixel)
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        try pngData.write(to: testFile)

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: testFile)

        // Should have at least one app that can open .png files (Preview at minimum)
        XCTAssertFalse(apps.isEmpty, "Should have apps available to open .png files")
    }

    // MARK: - Drag Pasteboard Tests

    @MainActor
    func testDragPasteboardContainsFileURLs() async throws {
        // Create test files
        let file1 = tempDir.appendingPathComponent("drag1.txt")
        let file2 = tempDir.appendingPathComponent("drag2.txt")
        try "A".write(to: file1, atomically: true, encoding: .utf8)
        try "B".write(to: file2, atomically: true, encoding: .utf8)

        let vc = FileListViewController()
        vc.loadView()
        vc.viewDidLoad()
        vc.loadDirectory(tempDir)

        // Test pasteboard writer for row
        let writer0 = vc.dataSource.tableView(vc.tableView, pasteboardWriterForRow: 0)
        let writer1 = vc.dataSource.tableView(vc.tableView, pasteboardWriterForRow: 1)

        XCTAssertNotNil(writer0, "Should return pasteboard writer for row 0")
        XCTAssertNotNil(writer1, "Should return pasteboard writer for row 1")

        // Verify the writer is an NSURL
        XCTAssertTrue(writer0 is NSURL, "Writer should be NSURL")
        XCTAssertTrue(writer1 is NSURL, "Writer should be NSURL")

        // Verify the writer is an NSURL
        guard let url0 = writer0 as? NSURL as URL?,
              let url1 = writer1 as? NSURL as URL? else {
            XCTFail("Writers should be NSURL")
            return
        }

        // Verify URLs match the files
        let itemURLs = vc.dataSource.items(at: IndexSet([0, 1])).map { $0.url }
        XCTAssertTrue(itemURLs.contains(url0), "Writer URL should match item URL")
        XCTAssertTrue(itemURLs.contains(url1), "Writer URL should match item URL")
    }

    // MARK: - Drop Target Tests

    @MainActor
    func testDropTargetRowTracking() async throws {
        // Create a test folder
        let testFolder = tempDir.appendingPathComponent("DropTarget")
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)

        let dataSource = FileListDataSource()
        dataSource.loadDirectory(tempDir)

        // Initially no drop target
        XCTAssertNil(dataSource.dropTargetRow)

        // Set drop target
        dataSource.dropTargetRow = 0
        XCTAssertEqual(dataSource.dropTargetRow, 0)

        // Clear drop target
        dataSource.dropTargetRow = nil
        XCTAssertNil(dataSource.dropTargetRow)
    }
}
