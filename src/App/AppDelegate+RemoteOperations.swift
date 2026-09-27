import AppKit

extension AppDelegate {
    @objc func showRemoteOperations(_ sender: Any?) {
        let controller = RemoteOperationsWindowController.shared
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }
}
