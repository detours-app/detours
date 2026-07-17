import AppKit
import XCTest
@testable import Detours

@MainActor
final class FileItemOpeningTests: XCTestCase {
    func testEnterOpensEverySelectedOrdinaryFileInVisibleOrder() {
        let items = [makeFile("charlie.txt"), makeFile("alpha.txt"), makeFile("bravo.txt")]
        var opened: [String] = []
        let dispatcher = makeDispatcher { item, _ in
            opened.append(item.name)
            return .success(())
        }

        let result = dispatcher.open(items: items, focusedItem: items[0])

        XCTAssertEqual(opened, ["charlie.txt", "alpha.txt", "bravo.txt"])
        XCTAssertEqual(result.attemptedItems.map(\.name), opened)
        XCTAssertEqual(result.openedItems.map(\.name), opened)
    }

    func testCommandOpenCommandDownAndContextMenuMatchEnter() {
        let controller = makeController(items: [makeFile("one.txt"), makeFile("two.txt")])
        var opened: [String] = []
        controller.openingActionOverride = { item, _ in
            opened.append(item.name)
            return .success(())
        }

        let entryPoints: [() -> Void] = [
            { XCTAssertTrue(controller.handleKeyDown(self.keyEvent(keyCode: 36, characters: "\r"))) },
            { XCTAssertTrue(controller.handleKeyDown(self.keyEvent(keyCode: 31, characters: "o", modifiers: .command))) },
            { XCTAssertTrue(controller.handleKeyDown(self.keyEvent(keyCode: 125, characters: "", modifiers: .command))) },
            { controller.openFromContextMenu(nil) },
        ]

        for entryPoint in entryPoints {
            opened.removeAll()
            entryPoint()
            XCTAssertEqual(opened, ["one.txt", "two.txt"])
        }
    }

    func testMixedSelectionSkipsSpecialItems() {
        let hostID = UUID()
        let ordinaryA = makeFile("a.txt")
        let folder = makeItem("Folder", path: "/Folder", isDirectory: true, hostID: hostID)
        let archive = makeItem("bundle.zip", path: "/bundle.zip", hostID: hostID)
        let diskImage = makeFile("installer.dmg")
        let ordinaryB = makeFile("b.txt")
        var actions: [(String, FileItemOpenAction)] = []
        let dispatcher = makeDispatcher { item, action in
            actions.append((item.name, action))
            return .success(())
        }

        let result = dispatcher.open(
            items: [ordinaryA, folder, archive, diskImage, ordinaryB],
            focusedItem: folder
        )

        XCTAssertEqual(actions.map(\.0), ["a.txt", "b.txt"])
        XCTAssertEqual(actions.map(\.1), [.ordinaryFile, .ordinaryFile])
        XCTAssertEqual(result.skippedItems.map(\.name), ["Folder", "bundle.zip", "installer.dmg"])
        XCTAssertFalse(result.performedFocusedAction)
    }

    func testSelectionWithoutOrdinaryFilesUsesFocusedItemAction() {
        let hostID = UUID()
        let folder = makeItem("Folder", path: "/Folder", isDirectory: true, hostID: hostID)
        let archive = makeItem("bundle.zip", path: "/bundle.zip", hostID: hostID)
        let diskImage = makeFile("installer.dmg")
        var actions: [(String, FileItemOpenAction)] = []
        let dispatcher = makeDispatcher { item, action in
            actions.append((item.name, action))
            return .success(())
        }

        let result = dispatcher.open(
            items: [folder, archive, diskImage],
            focusedItem: archive
        )

        XCTAssertEqual(actions.map(\.0), ["bundle.zip"])
        XCTAssertEqual(actions.map(\.1), [.archive])
        XCTAssertEqual(result.attemptedItems.map(\.name), ["bundle.zip"])
        XCTAssertEqual(result.skippedItems.map(\.name), ["Folder", "installer.dmg"])
        XCTAssertTrue(result.performedFocusedAction)
    }

    func testBatchContinuesAndAggregatesFailures() {
        let items = [makeFile("good.txt"), makeFile("bad-a.txt"), makeFile("bad-b.txt")]
        var attempted: [String] = []
        let dispatcher = makeDispatcher { item, _ in
            attempted.append(item.name)
            if item.name.hasPrefix("bad") {
                return .failure(TestOpenError.refused(item.name))
            }
            return .success(())
        }

        let result = dispatcher.open(items: items, focusedItem: items[0])

        XCTAssertEqual(attempted, items.map(\.name))
        XCTAssertEqual(result.openedItems.map(\.name), ["good.txt"])
        XCTAssertEqual(result.failures.map { $0.item.name }, ["bad-a.txt", "bad-b.txt"])
        XCTAssertEqual(result.failures.map { $0.error.localizedDescription }, [
            "Refused bad-a.txt",
            "Refused bad-b.txt",
        ])
    }

    func testOpeningMoreThanFiveFilesConfirmsFirst() {
        let six = (1...6).map { makeFile("\($0).txt") }
        var confirmationCounts: [Int] = []
        var opened: [String] = []
        let cancellingDispatcher = FileItemOpeningDispatcher(
            confirmsOpening: { count in
                confirmationCounts.append(count)
                return false
            },
            performsAction: { item, _ in
                opened.append(item.name)
                return .success(())
            }
        )

        let cancelled = cancellingDispatcher.open(items: six, focusedItem: six[0])

        XCTAssertEqual(confirmationCounts, [6])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(cancelled.wasCancelled)

        var fiveConfirmations = 0
        let five = Array(six.prefix(5))
        let fiveDispatcher = FileItemOpeningDispatcher(
            confirmsOpening: { _ in
                fiveConfirmations += 1
                return true
            },
            performsAction: { _, _ in .success(()) }
        )

        let result = fiveDispatcher.open(items: five, focusedItem: five[0])

        XCTAssertEqual(fiveConfirmations, 0)
        XCTAssertEqual(result.openedItems.count, 5)
        XCTAssertFalse(result.wasCancelled)
    }

    private func makeDispatcher(
        action: @escaping FileItemOpeningDispatcher.ActionPerformer
    ) -> FileItemOpeningDispatcher {
        FileItemOpeningDispatcher(
            confirmsOpening: { _ in true },
            performsAction: action
        )
    }

    private func makeController(items: [FileItem]) -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.dataSource.applier.setRootItems(items)
        controller.tableView.reloadData()
        controller.tableView.selectRowIndexes(
            IndexSet(integersIn: 0..<items.count),
            byExtendingSelection: false
        )
        return controller
    }

    private func makeFile(_ name: String) -> FileItem {
        FileItem(
            name: name,
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            isDirectory: false,
            size: 1,
            dateModified: Date(),
            icon: NSImage()
        )
    }

    private func makeItem(
        _ name: String,
        path: String,
        isDirectory: Bool = false,
        hostID: UUID
    ) -> FileItem {
        FileItem(
            name: name,
            location: .remote(hostID: hostID, path: path),
            isDirectory: isDirectory,
            size: isDirectory ? nil : 1,
            dateModified: Date(),
            icon: NSImage()
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

private enum TestOpenError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .refused(let name):
            return "Refused \(name)"
        }
    }
}
