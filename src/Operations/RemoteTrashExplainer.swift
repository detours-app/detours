import AppKit

enum RemoteTrashExplainer {
    static let dismissedDefaultsKey = "Detours.RemoteTrashExplainerDismissed"
    static let title = "Remote Trash Is Separate"
    static let message = """
    Deleted remote items move to a hidden Trash folder on that host, not to the Mac Trash.

    You can undo the delete from Detours while the operation is still in your undo history. To clear space later, empty the host trash manually over SSH at ~/.local/share/Trash.
    """

    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: dismissedDefaultsKey)
    }

    static func markDismissed(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissedDefaultsKey)
    }

    @MainActor
    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard shouldShow(defaults: defaults) else { return }
        show(defaults: defaults, includeDismissCheckbox: true)
    }

    @MainActor
    static func showFromHelp() {
        show(defaults: .standard, includeDismissCheckbox: false)
    }

    @MainActor
    private static func show(defaults: UserDefaults, includeDismissCheckbox: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        let checkbox: NSButton?
        if includeDismissCheckbox {
            let button = NSButton(checkboxWithTitle: "Do not show this again", target: nil, action: nil)
            button.state = .on
            alert.accessoryView = button
            checkbox = button
        } else {
            checkbox = nil
        }

        alert.runModal()

        if checkbox?.state == .on {
            markDismissed(defaults: defaults)
        }
    }
}
