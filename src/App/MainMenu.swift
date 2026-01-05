import AppKit

@MainActor
func setupMainMenu(target: AppDelegate) {
    let mainMenu = NSMenu()

    // Detour menu
    let appMenu = NSMenu()
    let appMenuItem = NSMenuItem(title: "Detour", action: nil, keyEquivalent: "")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    appMenu.addItem(withTitle: "About Detour", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Quit Detour", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // File menu
    let fileMenu = NSMenu(title: "File")
    let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    // Close Tab is now Cmd-W, Close Window is Cmd-Shift-W
    let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w")
    closeTabItem.target = target
    fileMenu.addItem(closeTabItem)

    let closeWindowItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
    closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
    fileMenu.addItem(closeWindowItem)

    // Edit menu - needs at least one item to be valid
    let editMenu = NSMenu(title: "Edit")
    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    // Add standard edit items so the menu isn't empty
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
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

    // Go menu
    let goMenu = NSMenu(title: "Go")
    let goMenuItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
    goMenuItem.submenu = goMenu
    mainMenu.addItem(goMenuItem)

    let backItem = NSMenuItem(title: "Back", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
    backItem.keyEquivalentModifierMask = .command
    backItem.target = target
    goMenu.addItem(backItem)

    let forwardItem = NSMenuItem(title: "Forward", action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
    forwardItem.keyEquivalentModifierMask = .command
    forwardItem.target = target
    goMenu.addItem(forwardItem)

    let enclosingItem = NSMenuItem(title: "Enclosing Folder", action: #selector(AppDelegate.goUp(_:)), keyEquivalent: "")
    enclosingItem.keyEquivalentModifierMask = .command
    enclosingItem.keyEquivalent = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    enclosingItem.target = target
    goMenu.addItem(enclosingItem)

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
