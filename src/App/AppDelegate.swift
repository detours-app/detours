import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu(target: self)

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Tab Actions

    @objc func newTab(_ sender: Any?) {
        mainWindowController?.splitViewController.newTab(sender)
    }

    @objc func closeTab(_ sender: Any?) {
        mainWindowController?.splitViewController.closeTab(sender)
    }

    @objc func selectNextTab(_ sender: Any?) {
        mainWindowController?.splitViewController.selectNextTab(sender)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        mainWindowController?.splitViewController.selectPreviousTab(sender)
    }

    // MARK: - Navigation Actions

    @objc func goBack(_ sender: Any?) {
        mainWindowController?.splitViewController.goBack(sender)
    }

    @objc func goForward(_ sender: Any?) {
        mainWindowController?.splitViewController.goForward(sender)
    }

    @objc func goUp(_ sender: Any?) {
        mainWindowController?.splitViewController.goUp(sender)
    }
}
