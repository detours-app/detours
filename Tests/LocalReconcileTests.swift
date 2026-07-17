import AppKit
import XCTest
@testable import Detours

/// T3 and T12: in-place local reconcile. Inserts, removes, and updates mutate
/// only the affected rows and preserve expansion, selection, and scroll; an
/// identical snapshot yields zero outline mutations and no redraw.
@MainActor
final class LocalReconcileTests: XCTestCase {
    private let rootURL = URL(fileURLWithPath: "/tmp/local-reconcile-fixture")
    private var root: Location { .local(rootURL) }

    private func item(_ name: String, isDirectory: Bool = false, children: [FileItem]? = nil) -> FileItem {
        let url = rootURL.appendingPathComponent(name)
        let made = FileItem(
            name: name,
            url: url,
            isDirectory: isDirectory,
            size: isDirectory ? nil : 1,
            dateModified: Date(timeIntervalSince1970: 100),
            icon: NSImage()
        )
        if let children {
            made.setChildrenForTesting(children)
            for child in children { child.parent = made }
        }
        return made
    }

    private func entry(from item: FileItem, size: Int64? = nil, date: Date? = nil) -> LoadedFileEntry {
        LoadedFileEntry(
            location: item.location,
            url: item.url,
            name: item.name,
            isDirectory: item.isDirectory,
            fileSize: size ?? item.size,
            contentModificationDate: date ?? item.dateModified
        )
    }

    private func controller(with items: [FileItem]) -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()
        controller.currentDirectory = rootURL
        controller.dataSource.displayedRootLocation = PaneRefreshScheduler.normalizedDirectory(root)
        controller.dataSource.applier.setRootItems(items)
        controller.dataSource.applier.reloadAll()
        return controller
    }

    private func apply(
        _ controller: FileListViewController,
        entries: [LoadedFileEntry],
        directory: Location? = nil,
        cause: PaneRefreshCause = .watcher
    ) -> PaneListingApplyOutcome {
        let request = PaneListingRequest(
            directory: directory ?? root,
            causes: [cause],
            policy: nil,
            epoch: controller.refreshScheduler.epoch,
            generation: 1
        )
        return controller.applyScheduledListingSnapshot(
            PaneListingSnapshot(request: request, entries: entries)
        )
    }

    func testInsertPreservesExpansionSelectionAndScrollWithoutFullReload() {
        let child = item("Folder/nested.txt")
        let folder = item("Folder", isDirectory: true, children: [child])
        let files = (0..<20).map { item("file-\(String(format: "%02d", $0)).txt") }
        let all = [folder] + files
        let controller = controller(with: all)
        controller.tableView.expandItem(folder)
        XCTAssertTrue(controller.tableView.isItemExpanded(folder))

        let selected = files[5]
        let row = controller.tableView.row(forItem: selected)
        controller.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 40))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        let scrollBefore = controller.scrollView.contentView.bounds.origin

        var entries = all.map { entry(from: $0) }
        entries.append(entry(from: item("file-05a-inserted.txt")))
        let reconciliation = controller.dataSource.reconcileListingEntries(entries, in: root)
        let kind = controller.dataSource.applier.applyReconciledListing(reconciliation!)

        XCTAssertEqual(kind, .rows, "An insert must not fall back to a full reload")
        XCTAssertTrue(controller.tableView.isItemExpanded(folder), "Expansion untouched")
        XCTAssertEqual(
            (controller.tableView.item(atRow: controller.tableView.selectedRow) as? FileItem)?.name,
            selected.name,
            "Selection tracks the item through the insert"
        )
        XCTAssertEqual(controller.scrollView.contentView.bounds.origin.y, scrollBefore.y, accuracy: 0.5)
    }

    func testRemoveMutatesOnlyAffectedRows() {
        let files = (0..<8).map { item("file-\($0).txt") }
        let controller = controller(with: files)
        let survivors = files.filter { $0.name != "file-3.txt" }

        let reconciliation = controller.dataSource.reconcileListingEntries(
            survivors.map { entry(from: $0) },
            in: root
        )
        let kind = controller.dataSource.applier.applyReconciledListing(reconciliation!)

        XCTAssertEqual(kind, .rows)
        XCTAssertEqual(controller.tableView.numberOfRows, 7)
        XCTAssertNil(controller.dataSource.items.first { $0.name == "file-3.txt" })
    }

    func testMetadataUpdateKeepsIdentityAndRowCount() {
        let files = (0..<4).map { item("file-\($0).txt") }
        let controller = controller(with: files)
        let target = controller.dataSource.items[2]

        let entries = files.map { source in
            entry(
                from: source,
                size: source.name == target.name ? 999 : nil,
                date: source.name == target.name ? Date(timeIntervalSince1970: 500) : nil
            )
        }
        let reconciliation = controller.dataSource.reconcileListingEntries(entries, in: root)
        XCTAssertEqual(reconciliation?.updatedItems, [ObjectIdentifier(target)])
        let kind = controller.dataSource.applier.applyReconciledListing(reconciliation!)

        XCTAssertEqual(kind, .rows)
        XCTAssertTrue(controller.dataSource.items[2] === target, "Item identity is stable")
        XCTAssertEqual(target.size, 999)
    }

    // MARK: - T12: idle-pane background changes

    func testIdenticalSnapshotYieldsZeroTableMutations() {
        let files = (0..<6).map { item("file-\($0).txt") }
        let controller = controller(with: files)
        controller.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        var loadNotifications = 0
        let spy = LoadCountingDelegate { loadNotifications += 1 }
        controller.navigationDelegate = spy

        PaneOutlineGuard.resetRecordedViolations()
        let violationsBefore = PaneOutlineGuard.recordedViolations.count
        let reconciliation = controller.dataSource.reconcileListingEntries(
            files.map { entry(from: $0) },
            in: root
        )
        XCTAssertTrue(reconciliation!.isNoop)
        let outcome = apply(controller, entries: files.map { entry(from: $0) })

        XCTAssertTrue(outcome.policyConsumed)
        XCTAssertEqual(loadNotifications, 0, "An unchanged listing causes no visible update")
        XCTAssertEqual(PaneOutlineGuard.recordedViolations.count, violationsBefore)
        XCTAssertEqual(controller.tableView.selectedRow, 2)
    }

    func testRealExternalChangeMutatesOnlyAffectedRowsKeepingSelectionAndScroll() {
        let files = (0..<20).map { item("file-\(String(format: "%02d", $0)).txt") }
        let controller = controller(with: files)
        let selected = controller.dataSource.items[4]
        controller.tableView.selectRowIndexes(
            IndexSet(integer: controller.tableView.row(forItem: selected)),
            byExtendingSelection: false
        )
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 30))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        let scrollBefore = controller.scrollView.contentView.bounds.origin

        var entries = files.map { entry(from: $0) }
        entries.append(entry(from: item("zz-external.txt")))
        let outcome = apply(controller, entries: entries)

        XCTAssertTrue(outcome.policyConsumed)
        XCTAssertEqual(controller.tableView.numberOfRows, 21)
        XCTAssertEqual(
            (controller.tableView.item(atRow: controller.tableView.selectedRow) as? FileItem)?.name,
            selected.name
        )
        XCTAssertEqual(controller.scrollView.contentView.bounds.origin.y, scrollBefore.y, accuracy: 0.5)
    }
}

@MainActor
private final class LoadCountingDelegate: FileListNavigationDelegate {
    private let onLoad: () -> Void
    init(onLoad: @escaping () -> Void) { self.onLoad = onLoad }

    func fileListDidRequestNavigation(to url: URL) {}
    func fileListDidRequestICloudSharedNavigation(cloudDocsURL: URL) {}
    func fileListDidRequestParentNavigation() {}
    func fileListDidRequestBack() {}
    func fileListDidRequestForward() {}
    func fileListDidRequestSwitchPane() {}
    func fileListDidBecomeActive() {}
    func fileListDidRequestOpenInNewTab(url: URL) {}
    func fileListDidRequestMoveToOtherPane(items: [Location]) {}
    func fileListDidRequestCopyToOtherPane(items: [Location]) {}
    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>) {}
    func fileListDidRequestRefreshSourceLocations(_ locations: Set<Location>) {}
    func fileListDidChangeSelection() {}
    func fileListDidLoadDirectory(_ controller: FileListViewController) { onLoad() }
}
