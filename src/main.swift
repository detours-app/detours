import AppKit

final class DetoursApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           ShortcutManager.shared.matches(event: event, action: .filter) {
            (delegate as? AppDelegate)?.filter(nil)
            return
        }

        super.sendEvent(event)
    }
}

let app = DetoursApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
