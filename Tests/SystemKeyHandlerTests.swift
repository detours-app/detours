import AppKit
import XCTest
@testable import Detours

@MainActor
final class SystemKeyHandlerTests: XCTestCase {
    func testSystemMediaKeyCodeParsingDetectsKeyDown() {
        let event = makeSystemDefinedKeyEvent(keyCode: SystemMediaKey.dictationKeyCode, keyDown: true)
        XCTAssertEqual(SystemMediaKey.keyCodeIfKeyDown(from: event), SystemMediaKey.dictationKeyCode)
    }

    func testSystemDefinedDictationKeyTriggersCopyToOtherPane() throws {
        let (splitVC, fileURL, cleanup) = try makeSplitViewControllerWithDestination()
        defer { cleanup() }

        let event = makeSystemDefinedKeyEvent(keyCode: SystemMediaKey.dictationKeyCode, keyDown: true)
        XCTAssertTrue(splitVC.handleSystemDefinedEvent(event))
    }

    func testSystemDefinedF5KeyTriggersCopyToOtherPane() throws {
        let (splitVC, fileURL, cleanup) = try makeSplitViewControllerWithDestination()
        defer { cleanup() }

        let event = makeSystemDefinedKeyEvent(keyCode: SystemMediaKey.f5KeyCode, keyDown: true)
        XCTAssertTrue(splitVC.handleSystemDefinedEvent(event))
    }

    func testGlobalKeyDownF5TriggersCopyToOtherPane() throws {
        let (splitVC, fileURL, cleanup) = try makeSplitViewControllerWithDestination()
        defer { cleanup() }

        let event = makeKeyDownEvent(functionKey: NSF5FunctionKey, keyCode: UInt16(SystemMediaKey.f5KeyCode))
        XCTAssertTrue(splitVC.handleGlobalKeyDown(event))
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

    private func makeSplitViewControllerWithDestination() throws -> (MainSplitViewController, URL, () -> Void) {
        let splitVC = MainSplitViewController()
        splitVC.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let sourceDir = try createTestFolder(in: temp, name: "source")
        let destDir = try createTestFolder(in: temp, name: "dest")
        let fileURL = try createTestFile(in: sourceDir, name: "a.txt")

        // Left pane: source with file selected
        let leftTab = try XCTUnwrap(splitVC.activePane.selectedTab)
        leftTab.navigate(to: sourceDir)
        leftTab.fileListViewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        // Right pane: destination
        let rightPane = splitVC.otherPane(from: splitVC.activePane)
        let rightTab = try XCTUnwrap(rightPane.selectedTab)
        rightTab.navigate(to: destDir)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }

        return (splitVC, fileURL, cleanup)
    }
}
