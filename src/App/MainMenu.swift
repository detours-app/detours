import AppKit

/// Menu items that update when shortcuts change
@MainActor
private var dynamicMenuItems: [ShortcutAction: NSMenuItem] = [:]

/// Reference to the view menu for dynamic tab updates
@MainActor
private var viewMenuDelegate: ViewMenuDelegate?

/// Reference to the window menu delegate
@MainActor
private var windowMenuDelegate: WindowMenuDelegate?

@MainActor
func setupMainMenu(target: AppDelegate) {
    let mainMenu = NSMenu()

    // Detours menu
    let appMenu = NSMenu()
    let appMenuItem = NSMenuItem(title: "Detours", action: nil, keyEquivalent: "")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    appMenu.addItem(withTitle: "About Detours", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())

    let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
    prefsItem.target = target
    appMenu.addItem(prefsItem)
    appMenu.addItem(NSMenuItem.separator())

    appMenu.addItem(withTitle: "Quit Detours", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // File menu
    let fileMenu = NSMenu(title: "File")
    let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    let newFolderItem = createDynamicMenuItem(
        title: "New Folder",
        action: #selector(FileListViewController.newFolder(_:)),
        shortcutAction: .newFolder
    )
    fileMenu.addItem(newFolderItem)

    // New File submenu
    let newFileMenu = NSMenu()

    let textFileItem = NSMenuItem(title: "Text File", action: #selector(FileListViewController.newTextFile(_:)), keyEquivalent: "n")
    textFileItem.keyEquivalentModifierMask = [.command, .option]
    newFileMenu.addItem(textFileItem)

    let markdownFileItem = NSMenuItem(title: "Markdown File", action: #selector(FileListViewController.newMarkdownFile(_:)), keyEquivalent: "")
    newFileMenu.addItem(markdownFileItem)

    newFileMenu.addItem(NSMenuItem.separator())

    let emptyFileItem = NSMenuItem(title: "Empty File...", action: #selector(FileListViewController.newEmptyFile(_:)), keyEquivalent: "")
    newFileMenu.addItem(emptyFileItem)

    let newFileMenuItem = NSMenuItem(title: "New File", action: nil, keyEquivalent: "")
    newFileMenuItem.submenu = newFileMenu
    fileMenu.addItem(newFileMenuItem)

    fileMenu.addItem(NSMenuItem.separator())

    let getInfoItem = NSMenuItem(title: "Get Info", action: #selector(FileListViewController.getInfo(_:)), keyEquivalent: "i")
    fileMenu.addItem(getInfoItem)

    let revealInFinderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(FileListViewController.showInFinder(_:)), keyEquivalent: "")
    fileMenu.addItem(revealInFinderItem)

    let showPackageContentsItem = NSMenuItem(title: "Show Package Contents", action: #selector(FileListViewController.showPackageContents), keyEquivalent: "")
    fileMenu.addItem(showPackageContentsItem)
    fileMenu.addItem(NSMenuItem.separator())

    // Close Tab is now Cmd-W, Close Window is Cmd-Shift-W
    let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w")
    closeTabItem.target = target
    fileMenu.addItem(closeTabItem)

    let closeWindowItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
    closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
    fileMenu.addItem(closeWindowItem)

    // Edit menu
    let editMenu = NSMenu(title: "Edit")
    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())

    let cutItem = NSMenuItem(title: "Cut", action: #selector(FileListViewController.cut(_:)), keyEquivalent: "x")
    let copyItem = NSMenuItem(title: "Copy", action: #selector(FileListViewController.copy(_:)), keyEquivalent: "c")
    let pasteItem = NSMenuItem(title: "Paste", action: #selector(FileListViewController.paste(_:)), keyEquivalent: "v")
    let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(FileListViewController.duplicate(_:)), keyEquivalent: "d")

    editMenu.addItem(cutItem)
    editMenu.addItem(copyItem)
    editMenu.addItem(pasteItem)
    editMenu.addItem(duplicateItem)
    editMenu.addItem(NSMenuItem.separator())

    let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(FileListViewController.copyPath(_:)), keyEquivalent: "c")
    copyPathItem.keyEquivalentModifierMask = [.command, .option]
    editMenu.addItem(copyPathItem)
    editMenu.addItem(NSMenuItem.separator())

    let deleteItem = NSMenuItem(title: "Move to Trash", action: #selector(FileListViewController.delete(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDeleteCharacter)!)))
    deleteItem.keyEquivalentModifierMask = NSEvent.ModifierFlags.command
    editMenu.addItem(deleteItem)
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    // View menu - Tab controls
    let viewMenu = NSMenu(title: "View")
    let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

    let newTabItem = NSMenuItem(title: "New Tab", action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t")
    newTabItem.target = target
    viewMenu.addItem(newTabItem)

    viewMenu.addItem(NSMenuItem.separator())

    // Dynamic tab selection items - populated by delegate
    let tabSectionStart = NSMenuItem.separator()
    tabSectionStart.tag = 1000  // Marker for tab section start
    viewMenu.addItem(tabSectionStart)

    // Set up delegate to dynamically populate tab items
    viewMenuDelegate = ViewMenuDelegate(target: target, tabSectionStartTag: 1000)
    viewMenu.delegate = viewMenuDelegate

    viewMenu.addItem(NSMenuItem.separator())

    let toggleHiddenItem = createDynamicMenuItem(
        title: "Toggle Hidden Files",
        action: #selector(AppDelegate.toggleHiddenFiles(_:)),
        shortcutAction: .toggleHiddenFiles,
        target: target
    )
    viewMenu.addItem(toggleHiddenItem)

    let showStatusBarItem = NSMenuItem(title: "Show Status Bar", action: #selector(AppDelegate.toggleStatusBar(_:)), keyEquivalent: "")
    showStatusBarItem.target = target
    viewMenu.addItem(showStatusBarItem)

    viewMenu.addItem(NSMenuItem.separator())

    let toggleSidebarItem = createDynamicMenuItem(
        title: "Toggle Sidebar",
        action: #selector(AppDelegate.toggleSidebar(_:)),
        shortcutAction: .toggleSidebar,
        target: target
    )
    viewMenu.addItem(toggleSidebarItem)

    // Go menu
    let goMenu = NSMenu(title: "Go")
    let goMenuItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
    goMenuItem.submenu = goMenu
    mainMenu.addItem(goMenuItem)

    let quickOpenItem = createDynamicMenuItem(
        title: "Quick Open",
        action: #selector(AppDelegate.quickOpen(_:)),
        shortcutAction: .quickOpen,
        target: target
    )
    goMenu.addItem(quickOpenItem)

    goMenu.addItem(NSMenuItem.separator())

    // Navigation items - Cmd+arrows for back/forward
    let backItem = NSMenuItem(title: "Back", action: #selector(FileListViewController.goBack(_:)), keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
    backItem.keyEquivalentModifierMask = .command
    goMenu.addItem(backItem)

    let forwardItem = NSMenuItem(title: "Forward", action: #selector(FileListViewController.goForward(_:)), keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
    forwardItem.keyEquivalentModifierMask = .command
    goMenu.addItem(forwardItem)

    let enclosingItem = NSMenuItem(title: "Enclosing Folder", action: #selector(FileListViewController.goUp(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
    enclosingItem.keyEquivalentModifierMask = .command
    goMenu.addItem(enclosingItem)

    goMenu.addItem(NSMenuItem.separator())

    let refreshItem = createDynamicMenuItem(
        title: "Refresh",
        action: #selector(AppDelegate.refresh(_:)),
        shortcutAction: .refresh,
        target: target
    )
    goMenu.addItem(refreshItem)

    goMenu.addItem(NSMenuItem.separator())

    // Tab navigation - Ctrl+Tab / Ctrl+Shift+Tab (Tab without modifier switches pane)
    let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(AppDelegate.selectNextTab(_:)), keyEquivalent: "\t")
    nextTabItem.keyEquivalentModifierMask = .control
    nextTabItem.target = target
    goMenu.addItem(nextTabItem)

    let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(AppDelegate.selectPreviousTab(_:)), keyEquivalent: "\t")
    prevTabItem.keyEquivalentModifierMask = [.control, .shift]
    prevTabItem.target = target
    goMenu.addItem(prevTabItem)

    // Window menu
    let windowMenu = NSMenu(title: "Window")
    let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

    NSApp.windowsMenu = windowMenu

    // Remove "Enter Full Screen" that macOS adds automatically
    windowMenuDelegate = WindowMenuDelegate()
    windowMenu.delegate = windowMenuDelegate

    // Help menu
    let helpMenu = NSMenu(title: "Help")
    let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    helpMenuItem.submenu = helpMenu
    mainMenu.addItem(helpMenuItem)

    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = mainMenu

    // Observe shortcut changes to update menu key equivalents
    NotificationCenter.default.addObserver(
        forName: ShortcutManager.shortcutsDidChange,
        object: nil,
        queue: .main
    ) { _ in
        Task { @MainActor in
            updateDynamicMenuItems()
        }
    }
}

// MARK: - Dynamic Menu Items

@MainActor
private func createDynamicMenuItem(
    title: String,
    action: Selector,
    shortcutAction: ShortcutAction,
    target: AnyObject? = nil
) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = target
    applyShortcut(to: item, for: shortcutAction)
    dynamicMenuItems[shortcutAction] = item
    return item
}

@MainActor
private func applyShortcut(to item: NSMenuItem, for shortcutAction: ShortcutAction) {
    if let keyEquivalent = ShortcutManager.shared.keyEquivalent(for: shortcutAction) {
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = ShortcutManager.shared.keyEquivalentModifierMask(for: shortcutAction)
    } else {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
    }
}

@MainActor
private func updateDynamicMenuItems() {
    for (action, item) in dynamicMenuItems {
        applyShortcut(to: item, for: action)
    }
}

// MARK: - View Menu Delegate

/// Delegate that dynamically populates tab selection items in the View menu
@MainActor
final class ViewMenuDelegate: NSObject, NSMenuDelegate {
    private weak var target: AppDelegate?
    private let tabSectionStartTag: Int

    init(target: AppDelegate, tabSectionStartTag: Int) {
        self.target = target
        self.tabSectionStartTag = tabSectionStartTag
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateTabItems(in: menu)
        removeFullScreenItem(from: menu)
    }

    private func removeFullScreenItem(from menu: NSMenu) {
        for item in menu.items where item.action == #selector(NSWindow.toggleFullScreen(_:)) {
            menu.removeItem(item)
        }
    }

    private func updateTabItems(in menu: NSMenu) {
        // Find the tab section start marker
        guard let startIndex = menu.items.firstIndex(where: { $0.tag == tabSectionStartTag }) else {
            return
        }

        // Remove existing dynamic tab items (tags 1-9)
        let itemsToRemove = menu.items.filter { $0.tag >= 1 && $0.tag <= 9 }
        for item in itemsToRemove {
            menu.removeItem(item)
        }

        // Get current tabs from the active pane
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let splitVC = appDelegate.mainWindowController?.splitViewController else {
            return
        }

        let activePane = splitVC.activePane
        let tabs = activePane.tabs

        // Insert tab items after the marker, limited to 9
        let insertIndex = startIndex + 1
        for (index, tab) in tabs.prefix(9).enumerated() {
            let tabNumber = index + 1
            let title = tab.title
            let item = NSMenuItem(
                title: title,
                action: #selector(AppDelegate.selectTabByNumber(_:)),
                keyEquivalent: "\(tabNumber)"
            )
            item.tag = tabNumber
            item.target = target

            // Mark current tab
            if index == activePane.selectedTabIndex {
                item.state = .on
            }

            menu.insertItem(item, at: insertIndex + index)
        }
    }
}

// MARK: - Window Menu Delegate

/// Delegate that removes the "Enter Full Screen" item macOS automatically adds
@MainActor
final class WindowMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Remove any Full Screen items that macOS adds
        for item in menu.items where item.action == #selector(NSWindow.toggleFullScreen(_:)) {
            menu.removeItem(item)
        }
    }
}
