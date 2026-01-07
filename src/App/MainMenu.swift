import AppKit

@MainActor
func setupMainMenu(target: AppDelegate) {
    let mainMenu = NSMenu()

    // Detour menu
    let appMenu = NSMenu()
    let appMenuItem = NSMenuItem(title: "Detour", action: nil, keyEquivalent: "")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    appMenu.addItem(withTitle: "About Detour", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Quit Detour", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // File menu
    let fileMenu = NSMenu(title: "File")
    let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(FileListViewController.newFolder(_:)), keyEquivalent: "n")
    newFolderItem.keyEquivalentModifierMask = [.command, .shift]
    fileMenu.addItem(newFolderItem)
    fileMenu.addItem(NSMenuItem.separator())

    let getInfoItem = NSMenuItem(title: "Get Info", action: #selector(FileListViewController.getInfo(_:)), keyEquivalent: "i")
    fileMenu.addItem(getInfoItem)

    let revealInFinderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(FileListViewController.showInFinder(_:)), keyEquivalent: "")
    fileMenu.addItem(revealInFinderItem)
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

    let nextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(AppDelegate.selectNextTab(_:)), keyEquivalent: "]")
    nextTabItem.keyEquivalentModifierMask = [.command, .shift]
    nextTabItem.target = target
    viewMenu.addItem(nextTabItem)

    let prevTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(AppDelegate.selectPreviousTab(_:)), keyEquivalent: "[")
    prevTabItem.keyEquivalentModifierMask = [.command, .shift]
    prevTabItem.target = target
    viewMenu.addItem(prevTabItem)

    viewMenu.addItem(NSMenuItem.separator())

    // Cmd+1 through Cmd+9 for tab selection
    for i in 1...9 {
        let tabItem = NSMenuItem(title: "Select Tab \(i)", action: #selector(AppDelegate.selectTabByNumber(_:)), keyEquivalent: "\(i)")
        tabItem.tag = i
        tabItem.target = target
        viewMenu.addItem(tabItem)
    }

    viewMenu.addItem(NSMenuItem.separator())

    let toggleHiddenItem = NSMenuItem(title: "Toggle Hidden Files", action: #selector(AppDelegate.toggleHiddenFiles(_:)), keyEquivalent: ".")
    toggleHiddenItem.keyEquivalentModifierMask = [.command, .shift]
    toggleHiddenItem.target = target
    viewMenu.addItem(toggleHiddenItem)

    // Go menu
    let goMenu = NSMenu(title: "Go")
    let goMenuItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
    goMenuItem.submenu = goMenu
    mainMenu.addItem(goMenuItem)

    let quickOpenItem = NSMenuItem(title: "Quick Open", action: #selector(AppDelegate.quickOpen(_:)), keyEquivalent: "p")
    quickOpenItem.keyEquivalentModifierMask = .command
    quickOpenItem.target = target
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

    let refreshItem = NSMenuItem(title: "Refresh", action: #selector(AppDelegate.refresh(_:)), keyEquivalent: "r")
    refreshItem.keyEquivalentModifierMask = .command
    refreshItem.target = target
    goMenu.addItem(refreshItem)

    // Window menu
    let windowMenu = NSMenu(title: "Window")
    let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

    NSApp.windowsMenu = windowMenu

    // Help menu
    let helpMenu = NSMenu(title: "Help")
    let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    helpMenuItem.submenu = helpMenu
    mainMenu.addItem(helpMenuItem)

    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = mainMenu
}
