import AppKit
import XCTest
@testable import Detours

/// Page Up and Page Down had no case in the file list key handler, so they fell through to
/// type-to-select. Function keys carry a private-use character, so the "any character with no
/// modifiers" test accepted them, the handler reported the key as handled, and the outline view
/// never got to page. Expanding a folder past one screenful is where that first bites.
@MainActor
final class PageKeyNavigationTests: XCTestCase {
    private let pageUpKeyCode: UInt16 = 116
    private let pageDownKeyCode: UInt16 = 121

    /// The paging step comes from the visible rect, which is only meaningful once the list is
    /// inside a real window, so each controller is hosted for the lifetime of its test.
    private var hostWindows: [NSWindow] = []

    override func tearDown() {
        hostWindows.removeAll()
        super.tearDown()
    }

    private func makeLoadedController(in directory: URL) -> FileListViewController {
        let controller = FileListViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        hostWindows.append(window)
        controller.loadViewIfNeeded()

        let spy = NavigationDelegateSpy()
        controller.navigationDelegate = spy
        let previousLoadCount = spy.directoryLoadCount
        let loaded = expectation(description: "directory loaded")
        spy.onDidLoadDirectory = {
            if spy.directoryLoadCount > previousLoadCount {
                loaded.fulfill()
            }
        }
        controller.loadDirectory(directory)
        wait(for: [loaded], timeout: 30)
        spy.onDidLoadDirectory = nil
        controller.view.layoutSubtreeIfNeeded()
        controller.tableView.layoutSubtreeIfNeeded()
        return controller
    }

    /// A directory with far more rows than fit on screen, named so sort order is index order.
    private func makeTallDirectory() throws -> URL {
        let temp = try createTempDirectory()
        for index in 0..<120 {
            _ = try createTestFile(in: temp, name: String(format: "file-%03d.txt", index))
        }
        return temp
    }

    private func keyEvent(_ character: String, keyCode: UInt16, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            // Real page keys also carry `.function`; the handler must not treat that as typing.
            modifierFlags: shift ? [.function, .shift] : [.function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func pageDownEvent(shift: Bool = false) -> NSEvent {
        keyEvent("\u{F72D}", keyCode: pageDownKeyCode, shift: shift)
    }

    private func pageUpEvent(shift: Bool = false) -> NSEvent {
        keyEvent("\u{F72C}", keyCode: pageUpKeyCode, shift: shift)
    }

    private func visibleRows(in controller: FileListViewController) -> Int {
        let scrollView = controller.tableView.enclosingScrollView
        let visible = scrollView?.documentVisibleRect ?? controller.tableView.visibleRect
        return max(1, controller.tableView.rows(in: visible).length)
    }

    func testPageDownMovesSelectionByAPage() throws {
        let temp = try makeTallDirectory()
        defer { cleanupTempDirectory(temp) }

        let controller = makeLoadedController(in: temp)
        let page = visibleRows(in: controller)
        XCTAssertGreaterThan(page, 1, "The fixture must be taller than one screen for paging to mean anything")
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(controller.handleKeyDown(pageDownEvent()))

        XCTAssertEqual(controller.tableView.selectedRow, page - 1, "Page Down moves a page, keeping one row of overlap")
    }

    func testPageUpReturnsToWhereAPageDownStarted() throws {
        let temp = try makeTallDirectory()
        defer { cleanupTempDirectory(temp) }

        let controller = makeLoadedController(in: temp)
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(controller.handleKeyDown(pageDownEvent()))
        XCTAssertTrue(controller.handleKeyDown(pageUpEvent()))

        XCTAssertEqual(controller.tableView.selectedRow, 0)
    }

    func testPageDownClampsAtTheLastRow() throws {
        let temp = try makeTallDirectory()
        defer { cleanupTempDirectory(temp) }

        let controller = makeLoadedController(in: temp)
        let lastRow = controller.tableView.numberOfRows - 1
        controller.tableView.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)

        XCTAssertTrue(controller.handleKeyDown(pageDownEvent()))

        XCTAssertEqual(controller.tableView.selectedRow, lastRow)
    }

    func testPageUpClampsAtTheFirstRow() throws {
        let temp = try makeTallDirectory()
        defer { cleanupTempDirectory(temp) }

        let controller = makeLoadedController(in: temp)
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(controller.handleKeyDown(pageUpEvent()))

        XCTAssertEqual(controller.tableView.selectedRow, 0)
    }

    func testShiftPageDownExtendsTheSelection() throws {
        let temp = try makeTallDirectory()
        defer { cleanupTempDirectory(temp) }

        let controller = makeLoadedController(in: temp)
        let page = visibleRows(in: controller)
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(controller.handleKeyDown(pageDownEvent(shift: true)))

        XCTAssertEqual(controller.tableView.selectedRowIndexes, IndexSet(integersIn: 0...(page - 1)))
    }

    func testPageDownWithNoSelectionSelectsTheFirstRow() throws {
        let temp = try makeTallDirectory()
        defer { cleanupTempDirectory(temp) }

        let controller = makeLoadedController(in: temp)
        controller.tableView.deselectAll(nil)

        XCTAssertTrue(controller.handleKeyDown(pageDownEvent()))

        XCTAssertEqual(controller.tableView.selectedRow, 0)
    }

    func testPageDownDoesNotFeedTypeToSelect() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        _ = try createTestFolder(in: temp, name: "alpha")
        _ = try createTestFolder(in: temp, name: "zulu")

        let controller = makeLoadedController(in: temp)

        XCTAssertTrue(controller.handleKeyDown(pageDownEvent()))

        // A page key used to land in the type-select buffer as an invisible character, so the very
        // next keystroke searched for "<pagedown>z" and matched nothing.
        let zEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 6
        )!
        XCTAssertTrue(controller.handleKeyDown(zEvent))

        let row = controller.tableView.selectedRow
        let item = controller.tableView.item(atRow: row) as? FileItem
        XCTAssertEqual(item?.name, "zulu")
    }
}
