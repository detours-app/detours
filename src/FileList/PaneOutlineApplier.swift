import AppKit

/// Capability value required by every programmatic mutation of a pane's displayed
/// tree (`FileListDataSource` root items, `FileItem.children`) and by the guarded
/// outline mutation APIs on `BandedOutlineView`. Only `PaneOutlineApplier` can
/// construct one, which makes the applier the single writer for outline state.
struct PaneOutlineMutationAuthority {
    fileprivate init() {}
}

/// Debug/test enforcement for the single-writer invariant. Direct outline
/// mutation calls outside an applier scope report a violation; release builds
/// carry no enforcement.
@MainActor
enum PaneOutlineGuard {
    /// Violations recorded since launch (test builds observe these).
    private(set) static var recordedViolations: [String] = []

    static var isEnforcementEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return NSClassFromString("XCTestCase") != nil
        #endif
    }()

    /// Handler invoked on an unauthorized mutation. Tests may replace it to
    /// assert that the guard trips; the default records and (outside tests)
    /// stops a debug build at the offending call.
    static var violationHandler: (String) -> Void = { message in
        recordedViolations.append(message)
        if NSClassFromString("XCTestCase") == nil {
            assertionFailure(message)
        }
    }

    static func reportViolation(api: StaticString) {
        guard isEnforcementEnabled else { return }
        violationHandler("Unauthorized outline mutation: \(api) called outside PaneOutlineApplier")
    }

    static func resetRecordedViolations() {
        recordedViolations = []
    }
}

/// The sole executor of programmatic outline mutations for one pane. Every
/// data-driven replacement or redraw of displayed items goes through here so
/// that a single writer owns the outline's structure and row content.
@MainActor
final class PaneOutlineApplier {
    private weak var dataSource: FileListDataSource?

    init(dataSource: FileListDataSource) {
        self.dataSource = dataSource
    }

    private var outlineView: NSOutlineView? {
        dataSource?.outlineView
    }

    /// Runs `body` with the mutation authority while the outline's guard scope
    /// is open. All applier operations funnel through this.
    @discardableResult
    func withAuthority<T>(_ body: (PaneOutlineMutationAuthority) throws -> T) rethrows -> T {
        let authority = PaneOutlineMutationAuthority()
        if let banded = outlineView as? BandedOutlineView {
            return try banded.performAuthorizedMutations(with: authority) {
                try body(authority)
            }
        }
        return try body(authority)
    }

    // MARK: - Model mutations

    func setRootItems(_ items: [FileItem]) {
        withAuthority { authority in
            dataSource?.setDisplayedItems(items, with: authority)
        }
    }

    func setChildren(_ children: [FileItem]?, of item: FileItem) {
        withAuthority { authority in
            item.setChildren(children, with: authority)
        }
    }

    // MARK: - Outline mutations

    /// Full reload: navigation transactions and legacy full-refresh paths only.
    func reloadAll() {
        withAuthority { _ in
            outlineView?.reloadData()
            outlineView?.needsLayout = true
        }
    }

    /// Reloads one item's subtree (or the whole outline when `item` is nil).
    func reloadSubtree(_ item: FileItem?) {
        withAuthority { _ in
            if let item {
                outlineView?.reloadItem(item, reloadChildren: true)
            } else {
                outlineView?.reloadData()
            }
            outlineView?.needsLayout = true
        }
    }

    /// Row-scoped redraw for content-only changes (icons, sizes, git badges,
    /// drop-target state). Never changes structure.
    func reloadRows(_ rowIndexes: IndexSet, columns columnIndexes: IndexSet) {
        guard !rowIndexes.isEmpty else { return }
        withAuthority { _ in
            outlineView?.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        }
    }

    func reloadRow(for item: FileItem, column: Int) {
        guard let outlineView else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        reloadRows(IndexSet(integer: row), columns: IndexSet(integer: column))
    }
}
