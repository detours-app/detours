import AppKit
import os.log
@preconcurrency import Quartz

// MARK: - FilterBarDelegate

extension FileListViewController: FilterBarDelegate {
    func filterBar(_ filterBar: FilterBarView, didChangeText text: String) {
        updateFilter(text)
    }

    func filterBarDidRequestClose(_ filterBar: FilterBarView) {
        hideFilterBar()
    }

    func filterBarDidRequestFocusList(_ filterBar: FilterBarView) {
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0 && tableView.numberOfRows > 0 {
            tableView.selectRowIndexes(
                IndexSet(integer: 0),
                byExtendingSelection: false,
                origin: .automatic
            )
        }
    }
}
