import AppKit
import XCTest
@testable import Detours

/// T2: the one pane-state restore rule. Preferred results win; all surviving
/// selections remain; deletion chooses the captured forward neighbor, then
/// the previous neighbor; empty results stay unselected; and there is no
/// row-number fallback.
@MainActor
final class PaneStateRestoreTests: XCTestCase {
    private let hostID = UUID()
    private var root: Location { .remote(hostID: hostID, path: "/") }

    private func item(_ name: String) -> FileItem {
        FileItem(
            name: name,
            location: .remote(hostID: hostID, path: "/\(name)"),
            isDirectory: false,
            size: 1,
            dateModified: Date(timeIntervalSince1970: 0),
            icon: NSImage()
        )
    }

    private func entry(from item: FileItem) -> LoadedFileEntry {
        LoadedFileEntry(
            location: item.location,
            url: URL(fileURLWithPath: item.location.path),
            name: item.name,
            isDirectory: item.isDirectory,
            fileSize: item.size,
            contentModificationDate: item.dateModified
        )
    }

    private func controller(with items: [FileItem]) -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()
        controller.currentRemoteLocation = root
        controller.dataSource.currentRemoteDirectoryForGit = root
        controller.dataSource.displayedRootLocation = PaneRefreshScheduler.normalizedDirectory(root)
        controller.dataSource.applier.setRootItems(items)
        controller.dataSource.applier.reloadAll()
        return controller
    }

    private func apply(
        _ controller: FileListViewController,
        entries: [LoadedFileEntry],
        policy: PaneRefreshResultPolicy? = nil
    ) {
        let request = PaneListingRequest(
            directory: root,
            causes: [.operation],
            policy: policy,
            epoch: controller.refreshScheduler.epoch,
            generation: 1
        )
        _ = controller.applyScheduledListingSnapshot(
            PaneListingSnapshot(request: request, entries: entries)
        )
    }

    private func selectedNames(_ controller: FileListViewController) -> [String] {
        controller.tableView.selectedRowIndexes.compactMap {
            (controller.tableView.item(atRow: $0) as? FileItem)?.name
        }
    }

    private func select(_ names: [String], in controller: FileListViewController) {
        var indexes = IndexSet()
        for name in names {
            if let found = controller.dataSource.items.first(where: { $0.name == name }) {
                let row = controller.tableView.row(forItem: found)
                if row >= 0 { indexes.insert(row) }
            }
        }
        controller.tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func runReveal() {
        // runResultReveal hops one main-actor turn.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testPreferredResultsOutrankSurvivingSelection() {
        let items = ["a.txt", "b.txt", "c.txt"].map(item)
        let controller = controller(with: items)
        select(["a.txt"], in: controller)

        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [items[2].location]
        apply(controller, entries: items.map(entry(from:)), policy: policy)
        runReveal()

        XCTAssertEqual(selectedNames(controller), ["c.txt"])
    }

    func testAllSurvivingSelectionsRemain() {
        let items = ["a.txt", "b.txt", "c.txt", "d.txt"].map(item)
        let controller = controller(with: items)
        select(["b.txt", "d.txt"], in: controller)

        // c.txt disappears; both selected items survive.
        let survivors = items.filter { $0.name != "c.txt" }
        apply(controller, entries: survivors.map(entry(from:)))

        XCTAssertEqual(Set(selectedNames(controller)), ["b.txt", "d.txt"])
    }

    func testDeletionChoosesForwardNeighborInDisplayedOrder() {
        let items = ["a.txt", "b.txt", "c.txt", "d.txt"].map(item)
        let controller = controller(with: items)
        select(["b.txt"], in: controller)

        let survivors = items.filter { $0.name != "b.txt" }
        apply(controller, entries: survivors.map(entry(from:)))

        XCTAssertEqual(selectedNames(controller), ["c.txt"])
    }

    func testDeletionFallsBackToPreviousNeighborWhenNoForwardSurvivor() {
        let items = ["a.txt", "b.txt", "c.txt"].map(item)
        let controller = controller(with: items)
        select(["c.txt"], in: controller)

        let survivors = items.filter { $0.name != "c.txt" }
        apply(controller, entries: survivors.map(entry(from:)))

        XCTAssertEqual(selectedNames(controller), ["b.txt"])
    }

    func testEmptyListingLeavesNoSelection() {
        let items = ["a.txt", "b.txt"].map(item)
        let controller = controller(with: items)
        select(["a.txt"], in: controller)

        apply(controller, entries: [])

        XCTAssertTrue(selectedNames(controller).isEmpty)
    }

    func testNoRowNumberFallbackWhenListingIsReplaced() {
        let items = ["a.txt", "b.txt", "c.txt"].map(item)
        let controller = controller(with: items)
        select(["b.txt"], in: controller)

        // A completely different listing: nothing survives, no neighbor
        // exists, and row-number guessing must not select an unrelated file.
        let replacement = ["x.txt", "y.txt", "z.txt"].map(item)
        apply(controller, entries: replacement.map(entry(from:)))

        XCTAssertTrue(
            selectedNames(controller).isEmpty,
            "Selection must not jump to an unrelated file via a row-number fallback"
        )
    }
}
