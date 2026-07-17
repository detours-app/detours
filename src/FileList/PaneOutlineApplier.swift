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

    // MARK: - Reconciled listing apply

    enum ReconciliationApplyKind {
        /// Identical listing: no outline mutation, no redraw.
        case noop
        /// Row-level inserts/removes/updates only; expansion untouched.
        case rows
        /// Order changed: the parent subtree reloaded (item identity preserved).
        case subtree
    }

    /// Applies one reconciled listing with the smallest possible mutation.
    /// An identical later snapshot changes neither cells nor pane state; adds
    /// and removals mutate only the affected rows; a reorder falls back to an
    /// identity-preserving subtree reload.
    func applyReconciledListing(
        _ reconciliation: FileListDataSource.ListingReconciliation
    ) -> ReconciliationApplyKind {
        guard let dataSource, let outlineView else { return .noop }
        if reconciliation.isNoop {
            return .noop
        }

        let parent = reconciliation.parentItem
        // A collapsed branch has no materialized rows; reload its subtree
        // cheaply instead of issuing structural row operations.
        if let parent, !outlineView.isItemExpanded(parent) {
            reloadSubtree(parent)
            return .subtree
        }
        let oldVisible = dataSource.filteredProjection(of: reconciliation.previousItems)
        let newVisible = dataSource.filteredProjection(of: reconciliation.reconciledItems)
        let oldIDs = oldVisible.map(ObjectIdentifier.init)
        let newIDs = newVisible.map(ObjectIdentifier.init)
        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)

        var removedIndexes = IndexSet()
        for (index, id) in oldIDs.enumerated() where !newSet.contains(id) {
            removedIndexes.insert(index)
        }
        var insertedIndexes = IndexSet()
        for (index, id) in newIDs.enumerated() where !oldSet.contains(id) {
            insertedIndexes.insert(index)
        }
        let oldSurvivors = oldIDs.filter { newSet.contains($0) }
        let newSurvivors = newIDs.filter { oldSet.contains($0) }
        let orderPreserved = oldSurvivors == newSurvivors

        if !orderPreserved {
            reloadSubtree(parent)
            return .subtree
        }

        withAuthority { _ in
            if !removedIndexes.isEmpty || !insertedIndexes.isEmpty {
                outlineView.beginUpdates()
                if !removedIndexes.isEmpty {
                    outlineView.removeItems(at: removedIndexes, inParent: parent, withAnimation: [])
                }
                if !insertedIndexes.isEmpty {
                    outlineView.insertItems(at: insertedIndexes, inParent: parent, withAnimation: [])
                }
                outlineView.endUpdates()
            }
            if !reconciliation.updatedItems.isEmpty {
                var updatedRows = IndexSet()
                for item in newVisible where reconciliation.updatedItems.contains(ObjectIdentifier(item)) {
                    let row = outlineView.row(forItem: item)
                    if row >= 0 { updatedRows.insert(row) }
                }
                if !updatedRows.isEmpty {
                    let allColumns = IndexSet(integersIn: 0..<max(1, outlineView.numberOfColumns))
                    outlineView.reloadData(forRowIndexes: updatedRows, columnIndexes: allColumns)
                }
            }
            outlineView.needsLayout = true
        }
        return .rows
    }
}
