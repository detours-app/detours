import AppKit
import os.log
@preconcurrency import Quartz

// MARK: - Menu Validation

extension FileListViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return !selectedLocations.isEmpty
        case #selector(getInfo(_:)):
            return !selectedLocations.isEmpty
        case #selector(showInFinder(_:)), #selector(shareViaService(_:)):
            return !selectedURLs.isEmpty
        case #selector(copyPath(_:)):
            return !selectedLocations.isEmpty
        case #selector(cut(_:)):
            return !selectedLocations.isEmpty && !isSharedTopLevelView
        case #selector(duplicate(_:)):
            return !selectedURLs.isEmpty && !isSharedTopLevelView
        case #selector(archive(_:)):
            return !selectedLocations.isEmpty && !isSharedTopLevelView
        case #selector(delete(_:)), #selector(deleteImmediately(_:)):
            return !selectedLocations.isEmpty && !isSharedTopLevelView
        case #selector(renameFromContextMenu(_:)):
            return selectedLocations.count == 1 && !isSharedTopLevelView
        case #selector(openFromContextMenu(_:)):
            return !selectedLocations.isEmpty
        case #selector(openWithApp(_:)), #selector(openRemoteWithEditor(_:)), #selector(openWithOtherApp(_:)):
            return !selectedLocations.isEmpty && !isSharedTopLevelView
        case #selector(duplicateStructureFromContextMenu(_:)):
            if let item = menuItem.representedObject as? FileItem {
                return item.isLocal && item.isNavigableFolder && !isSharedTopLevelView
            }
            let items = selectedItems
            return items.count == 1
                && items[0].isLocal
                && items[0].isNavigableFolder
                && !isSharedTopLevelView
        case #selector(extractArchive(_:)):
            return Self.isExtractableSelection(selectedLocations)
        case #selector(paste(_:)):
            return ClipboardManager.shared.hasValidLocations
                && (currentDirectory != nil || currentRemoteLocation != nil)
                && !isSharedTopLevelView
        case #selector(newFolder(_:)), #selector(newTextFile(_:)), #selector(newMarkdownFile(_:)), #selector(newEmptyFile(_:)):
            return (currentDirectory != nil || currentRemoteLocation != nil) && !isSharedTopLevelView
        case #selector(showPackageContents):
            let row = tableView.selectedRow
            guard row >= 0, let item = dataSource.item(at: row) else { return false }
            return item.isPackage
        default:
            return true
        }
    }
}
