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
}
