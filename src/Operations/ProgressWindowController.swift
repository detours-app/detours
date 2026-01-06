import AppKit
import SwiftUI

final class ProgressWindowController: NSWindowController {
    private let model: ProgressModel
    var onCancel: (() -> Void)?

    init(progress: FileOperationProgress, onCancel: (() -> Void)?) {
        self.model = ProgressModel(progress: progress)
        let cancelHandler = onCancel
        let hostingView = NSHostingView(rootView: OperationProgressView(model: model) {
            cancelHandler?()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "File Operation"

        super.init(window: window)
        self.onCancel = onCancel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ progress: FileOperationProgress) {
        model.progress = progress
    }

    func show(over parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
    }

    func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}
