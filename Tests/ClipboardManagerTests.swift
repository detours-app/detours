import AppKit
import XCTest
@testable import Detours

@MainActor
final class ClipboardManagerTests: XCTestCase {
    private var previousItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        previousItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                }
            }
            return clone
        }
        ClipboardManager.shared.clear()
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if !previousItems.isEmpty {
            NSPasteboard.general.writeObjects(previousItems)
        }
        super.tearDown()
    }

    func testCopyWritesToPasteboard() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.copy(items: [file])

        let items = ClipboardManager.shared.items
        XCTAssertEqual(items, [file])
    }

    func testCutSetsIsCutFlag() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.isCut)
    }

    func testCopyClearsIsCutFlag() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])
        ClipboardManager.shared.copy(items: [file])

        XCTAssertFalse(ClipboardManager.shared.isCut)
    }

    func testHasItemsTrue() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.copy(items: [file])
        XCTAssertTrue(ClipboardManager.shared.hasItems)
    }

    func testHasItemsFalse() {
        XCTAssertFalse(ClipboardManager.shared.hasItems)
    }

    func testClearResetsState() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])
        ClipboardManager.shared.clear()

        XCTAssertFalse(ClipboardManager.shared.isCut)
        XCTAssertFalse(ClipboardManager.shared.hasItems)
    }

    func testCutPopulatesCutItemURLs() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.cutItemURLs.contains(file))
    }

    func testIsItemCut() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.isItemCut(file))
        XCTAssertFalse(ClipboardManager.shared.isItemCut(temp))
    }
}
