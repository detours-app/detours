import AppKit
import XCTest
@testable import Detour

@MainActor
final class SystemKeyHandlerTests: XCTestCase {
    func testSystemMediaKeyCodeParsingDetectsKeyDown() {
        let event = makeSystemDefinedKeyEvent(keyCode: SystemMediaKey.dictationKeyCode, keyDown: true)
        XCTAssertEqual(SystemMediaKey.keyCodeIfKeyDown(from: event), SystemMediaKey.dictationKeyCode)
    }

    func testSystemDefinedDictationKeyTriggersCopy() throws {
        let (splitVC, fileURL, cleanup) = try makeSplitViewControllerWithSelection()
        defer { cleanup() }

        let event = makeSystemDefinedKeyEvent(keyCode: SystemMediaKey.dictationKeyCode, keyDown: true)
        XCTAssertTrue(splitVC.handleSystemDefinedEvent(event))

        XCTAssertTrue(clipboardContains(fileURL))
    }

    func testSystemDefinedF5KeyTriggersCopy() throws {
        let (splitVC, fileURL, cleanup) = try makeSplitViewControllerWithSelection()
        defer { cleanup() }

        let event = makeSystemDefinedKeyEvent(keyCode: SystemMediaKey.f5KeyCode, keyDown: true)
        XCTAssertTrue(splitVC.handleSystemDefinedEvent(event))
        XCTAssertTrue(clipboardContains(fileURL))
    }

    func testGlobalKeyDownF5TriggersCopy() throws {
        let (splitVC, fileURL, cleanup) = try makeSplitViewControllerWithSelection()
        defer { cleanup() }

        let event = makeKeyDownEvent(functionKey: NSF5FunctionKey, keyCode: UInt16(SystemMediaKey.f5KeyCode))
        XCTAssertTrue(splitVC.handleGlobalKeyDown(event))
        XCTAssertTrue(clipboardContains(fileURL))
    }

    private func makeSystemDefinedKeyEvent(keyCode: Int, keyDown: Bool) -> NSEvent {
        let keyState = keyDown ? SystemMediaKey.keyDownFlag : 0xB
        let data1 = (keyCode << 16) | (keyState << 8)
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: SystemMediaKey.systemDefinedSubtype,
            data1: data1,
            data2: -1
        )!
    }

    private func makeKeyDownEvent(functionKey: Int, keyCode: UInt16) -> NSEvent {
        let chars = String(UnicodeScalar(functionKey)!)
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func makeSplitViewControllerWithSelection() throws -> (MainSplitViewController, URL, () -> Void) {
        let splitVC = MainSplitViewController()
        splitVC.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let fileURL = try createTestFile(in: temp, name: "a.txt")

        let tab = try XCTUnwrap(splitVC.activePane.selectedTab)
        tab.navigate(to: temp)

        let fileList = tab.fileListViewController
        fileList.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }

        return (splitVC, fileURL, cleanup)
    }

    private func clipboardContains(_ fileURL: URL) -> Bool {
        ClipboardManager.shared.items.contains { $0.standardizedFileURL == fileURL.standardizedFileURL }
    }
}
