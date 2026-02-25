import XCTest
@testable import Detours

@MainActor
final class PaneTabTests: XCTestCase {
    func testInitialState() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let tab = PaneTab(directory: temp)
        XCTAssertFalse(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
    }

    func testNavigateAddsToBackStack() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let next = try createTestFolder(in: temp, name: "Next")
        let tab = PaneTab(directory: temp)
        tab.navigate(to: next)

        XCTAssertTrue(tab.canGoBack)
    }

    func testGoBackMovesToForwardStack() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let next = try createTestFolder(in: temp, name: "Next")
        let tab = PaneTab(directory: temp)
        tab.navigate(to: next)
        XCTAssertTrue(tab.goBack())

        XCTAssertTrue(tab.canGoForward)
    }

    func testGoForwardMovesFromForwardStack() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let next = try createTestFolder(in: temp, name: "Next")
        let tab = PaneTab(directory: temp)
        tab.navigate(to: next)
        _ = tab.goBack()
        XCTAssertTrue(tab.goForward())

        XCTAssertTrue(tab.canGoBack)
    }

    func testGoUpNavigatesToParent() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let child = try createTestFolder(in: temp, name: "Child")
        let tab = PaneTab(directory: child)
        XCTAssertTrue(tab.goUp())
        XCTAssertEqual(tab.currentDirectory.path, temp.path)
    }

    func testGoUpAtRootReturnsFalse() {
        let tab = PaneTab(directory: URL(fileURLWithPath: "/"))
        XCTAssertFalse(tab.goUp())
    }

    func testTitleReturnsLastComponent() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let tab = PaneTab(directory: temp)
        XCTAssertEqual(tab.title, temp.lastPathComponent)
    }

    func testCanGoBackWhenStackEmpty() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let tab = PaneTab(directory: temp)
        XCTAssertFalse(tab.canGoBack)
    }

    func testCanGoBackWhenStackHasItems() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let next = try createTestFolder(in: temp, name: "Next")
        let tab = PaneTab(directory: temp)
        tab.navigate(to: next)

        XCTAssertTrue(tab.canGoBack)
    }

    func testNavigateClearsForwardStack() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let next = try createTestFolder(in: temp, name: "Next")
        let other = try createTestFolder(in: temp, name: "Other")
        let tab = PaneTab(directory: temp)
        tab.navigate(to: next)
        _ = tab.goBack()
        tab.navigate(to: other)

        XCTAssertFalse(tab.canGoForward)
    }

    func testHistoryPreservesICloudListingMode() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let mobileDocs = try createTestFolder(in: temp, name: "Mobile Documents")
        let cloudDocs = try createTestFolder(in: mobileDocs, name: "com~apple~CloudDocs")
        let nested = try createTestFolder(in: cloudDocs, name: "Nested")

        let tab = PaneTab(directory: mobileDocs)
        tab.navigate(to: cloudDocs, iCloudListingMode: .sharedTopLevel)
        XCTAssertEqual(tab.iCloudListingMode, .sharedTopLevel)

        tab.navigate(to: nested, iCloudListingMode: .sharedTopLevel)
        XCTAssertEqual(tab.iCloudListingMode, .sharedTopLevel)

        XCTAssertTrue(tab.goBack())
        XCTAssertEqual(tab.currentDirectory.standardizedFileURL, cloudDocs.standardizedFileURL)
        XCTAssertEqual(tab.iCloudListingMode, .sharedTopLevel)

        XCTAssertTrue(tab.goForward())
        XCTAssertEqual(tab.currentDirectory.standardizedFileURL, nested.standardizedFileURL)
        XCTAssertEqual(tab.iCloudListingMode, .sharedTopLevel)
    }

    func testGoUpBehaviorUnchangedForICloudContainers() throws {
        let fileManager = FileManager.default
        let mobileDocs = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents")
        let documents = mobileDocs
            .appendingPathComponent("com~detours~\(UUID().uuidString)")
            .appendingPathComponent("Documents")

        let tab = PaneTab(directory: documents)
        XCTAssertTrue(tab.goUp())
        XCTAssertEqual(tab.currentDirectory.standardizedFileURL, mobileDocs.standardizedFileURL)
    }

    func testSharedContextGoUpFromNestedFolderGoesToSharedRoot() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let mobileDocs = try createTestFolder(in: temp, name: "Mobile Documents")
        let cloudDocs = try createTestFolder(in: mobileDocs, name: "com~apple~CloudDocs")
        let sharedRoot = try createTestFolder(in: cloudDocs, name: "Steuern Tanja")
        let nested = try createTestFolder(in: sharedRoot, name: "Steuerperiode 2025")

        let tab = PaneTab(directory: cloudDocs, iCloudListingMode: .sharedTopLevel)
        tab.navigate(to: sharedRoot, iCloudListingMode: .sharedTopLevel)
        tab.navigate(to: nested, iCloudListingMode: .sharedTopLevel)

        XCTAssertTrue(tab.goUp())
        XCTAssertEqual(tab.currentDirectory.standardizedFileURL, sharedRoot.standardizedFileURL)
        XCTAssertEqual(tab.iCloudListingMode, .sharedTopLevel)
    }

    func testSharedContextGoUpFromSharedRootReturnsToSharedList() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let mobileDocs = try createTestFolder(in: temp, name: "Mobile Documents")
        let cloudDocs = try createTestFolder(in: mobileDocs, name: "com~apple~CloudDocs")
        let sharedRoot = try createTestFolder(in: cloudDocs, name: "Steuern Tanja")

        let tab = PaneTab(directory: cloudDocs, iCloudListingMode: .sharedTopLevel)
        tab.navigate(to: sharedRoot, iCloudListingMode: .sharedTopLevel)

        XCTAssertTrue(tab.goUp())
        XCTAssertEqual(tab.currentDirectory.standardizedFileURL, cloudDocs.standardizedFileURL)
        XCTAssertEqual(tab.iCloudListingMode, .sharedTopLevel)
    }
}
