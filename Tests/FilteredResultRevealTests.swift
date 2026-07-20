import AppKit
import XCTest
@testable import Detours

/// T18: an explicit operation result hidden by the targeted tab's filter
/// clears only that filter and selects the result in the same apply;
/// background intents never clear a filter.
@MainActor
final class FilteredResultRevealTests: XCTestCase {
    private let rootURL = URL(fileURLWithPath: "/tmp/filtered-reveal-fixture")
    private var root: Location { .local(rootURL) }

    private func item(_ name: String) -> FileItem {
        FileItem(
            name: name,
            url: rootURL.appendingPathComponent(name),
            isDirectory: false,
            size: 1,
            dateModified: Date(timeIntervalSince1970: 100),
            icon: NSImage()
        )
    }

    private func entry(from item: FileItem) -> LoadedFileEntry {
        LoadedFileEntry(
            location: item.location,
            url: item.url,
            name: item.name,
            isDirectory: false,
            fileSize: 1
        )
    }

    private func makeFilteredController(items: [FileItem], filter: String) -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()
        controller.currentDirectory = rootURL
        controller.dataSource.displayedRootLocation = PaneRefreshScheduler.normalizedDirectory(root)
        controller.dataSource.applier.setRootItems(items)
        controller.showFilterBar()
        controller.filterBar.filterText = filter
        controller.updateFilter(filter)
        return controller
    }

    private func apply(
        _ controller: FileListViewController,
        entries: [LoadedFileEntry],
        cause: PaneRefreshCause,
        policy: PaneRefreshResultPolicy? = nil
    ) -> PaneListingApplyOutcome {
        let request = PaneListingRequest(
            directory: root,
            causes: [cause],
            policy: policy,
            epoch: controller.refreshScheduler.epoch,
            generation: 1
        )
        return controller.applyScheduledListingSnapshot(
            PaneListingSnapshot(request: request, entries: entries)
        )
    }

    private func runReveal() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    func testClearingFilterPreservesSelectedItemInsteadOfFilteredRowIndex() {
        let existing = [item("0-first.txt"), item("alpha-selected.txt"), item("zeta.txt")]
        let controller = makeFilteredController(items: existing, filter: "alpha")
        XCTAssertEqual(controller.tableView.numberOfRows, 1)
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        controller.hideFilterBar()

        let selected = controller.tableView.item(atRow: controller.tableView.selectedRow) as? FileItem
        XCTAssertEqual(selected?.name, "alpha-selected.txt")
    }

    func testExplicitResultHiddenByFilterClearsOnlyThisTabsFilter() {
        let existing = [item("report-a.txt"), item("report-b.txt"), item("notes.txt")]
        let controller = makeFilteredController(items: existing, filter: "report")
        XCTAssertEqual(controller.tableView.numberOfRows, 2, "Filter hides notes.txt")

        // A copy lands a file the filter hides.
        let copied = item("incoming.pdf")
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [copied.location]
        policy.clearsFilterConcealingResults = true
        let outcome = apply(
            controller,
            entries: (existing + [copied]).map(entry(from:)),
            cause: .operation,
            policy: policy
        )
        runReveal()

        XCTAssertTrue(outcome.policyConsumed)
        XCTAssertFalse(controller.isFilterBarVisible, "The targeted tab's filter clears")
        XCTAssertNil(controller.dataSource.filterPredicate)
        let row = controller.tableView.selectedRow
        XCTAssertEqual(
            (controller.tableView.item(atRow: row) as? FileItem)?.name,
            "incoming.pdf",
            "The result ends selected and visible"
        )
    }

    func testVisibleResultLeavesFilterAlone() {
        let existing = [item("report-a.txt"), item("notes.txt")]
        let controller = makeFilteredController(items: existing, filter: "report")

        let copied = item("report-new.txt")
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [copied.location]
        policy.clearsFilterConcealingResults = true
        _ = apply(
            controller,
            entries: (existing + [copied]).map(entry(from:)),
            cause: .operation,
            policy: policy
        )
        runReveal()

        XCTAssertTrue(controller.isFilterBarVisible, "A visible result never clears the filter")
        XCTAssertEqual(controller.dataSource.filterPredicate, "report")
    }

    func testBackgroundIntentNeverClearsTheFilter() {
        let existing = [item("report-a.txt"), item("notes.txt")]
        let controller = makeFilteredController(items: existing, filter: "report")

        let external = item("zz-external.pdf")
        _ = apply(
            controller,
            entries: (existing + [external]).map(entry(from:)),
            cause: .watcher
        )
        runReveal()

        XCTAssertTrue(controller.isFilterBarVisible, "Watcher intents never clear a filter")
        XCTAssertEqual(controller.dataSource.filterPredicate, "report")
        XCTAssertEqual(controller.tableView.numberOfRows, 1, "The hidden external file stays hidden")
    }
}
