import AppKit
import os.log

private let logger = Logger(subsystem: "com.detour", category: "events")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var systemEventMonitor: Any?
    private var keyDownEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu(target: self)

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        systemEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            logger.warning("systemDefined event: type=\(event.type.rawValue) subtype=\(event.subtype.rawValue) data1=\(event.data1)")
            guard let splitVC = self?.mainWindowController?.splitViewController else {
                logger.error("systemDefined: splitVC is nil")
                return event
            }
            let handled = splitVC.handleSystemDefinedEvent(event)
            logger.warning("systemDefined handled=\(handled)")
            return handled ? nil : event
        }

        keyDownEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            logger.warning("keyDown event: keyCode=\(event.keyCode) chars=\(event.characters ?? "nil")")
            guard let splitVC = self?.mainWindowController?.splitViewController else {
                logger.error("keyDown: splitVC is nil")
                return event
            }
            let handled = splitVC.handleGlobalKeyDown(event)
            logger.warning("keyDown handled=\(handled)")
            return handled ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.splitViewController.saveSession()

        // Close any Finder info windows we opened
        let script = NSAppleScript(source: """
            tell application "Finder"
                close every information window
            end tell
            """)
        script?.executeAndReturnError(nil)

        if let monitor = systemEventMonitor {
            NSEvent.removeMonitor(monitor)
            systemEventMonitor = nil
        }

        if let monitor = keyDownEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownEventMonitor = nil
        }
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

    @objc func refresh(_ sender: Any?) {
        mainWindowController?.splitViewController.refresh(sender)
    }

    @objc func quickOpen(_ sender: Any?) {
        mainWindowController?.splitViewController.quickOpen(sender)
    }
}
