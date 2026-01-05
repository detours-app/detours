import AppKit

@MainActor
func setupMainMenu() {
    let mainMenu = NSMenu()

    // Detour menu
    let appMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    appMenu.addItem(withTitle: "About Detour", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Quit Detour", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // File menu
    let fileMenu = NSMenu(title: "File")
    let fileMenuItem = NSMenuItem()
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

    // Edit menu (placeholder)
    let editMenu = NSMenu(title: "Edit")
    let editMenuItem = NSMenuItem()
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    // View menu (placeholder)
    let viewMenu = NSMenu(title: "View")
    let viewMenuItem = NSMenuItem()
    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

    // Go menu
    let goMenu = NSMenu(title: "Go")
    let goMenuItem = NSMenuItem()
    goMenuItem.submenu = goMenu
    mainMenu.addItem(goMenuItem)

    let backItem = NSMenuItem(title: "Back", action: #selector(MainSplitViewController.goBack(_:)), keyEquivalent: "")
    backItem.keyEquivalentModifierMask = .command
    backItem.keyEquivalent = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    goMenu.addItem(backItem)

    let forwardItem = NSMenuItem(title: "Forward", action: #selector(MainSplitViewController.goForward(_:)), keyEquivalent: "")
    forwardItem.keyEquivalentModifierMask = .command
    forwardItem.keyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    goMenu.addItem(forwardItem)

    let enclosingItem = NSMenuItem(title: "Enclosing Folder", action: #selector(MainSplitViewController.goUp(_:)), keyEquivalent: "")
    enclosingItem.keyEquivalentModifierMask = .command
    enclosingItem.keyEquivalent = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    goMenu.addItem(enclosingItem)

    // Window menu
    let windowMenu = NSMenu(title: "Window")
    let windowMenuItem = NSMenuItem()
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

    NSApp.windowsMenu = windowMenu

    // Help menu (placeholder)
    let helpMenu = NSMenu(title: "Help")
    let helpMenuItem = NSMenuItem()
    helpMenuItem.submenu = helpMenu
    mainMenu.addItem(helpMenuItem)

    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = mainMenu
}
