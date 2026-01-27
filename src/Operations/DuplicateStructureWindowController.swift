import AppKit
import SwiftUI

final class DuplicateStructureWindowController: NSWindowController {
    private let model: DuplicateStructureModel
    var onComplete: ((URL, (String, String)?) -> Void)?

    init(sourceURL: URL, completion: @escaping (URL, (String, String)?) -> Void) {
        self.model = DuplicateStructureModel(sourceURL: sourceURL)
        self.onComplete = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Duplicate Structure"

        super.init(window: window)

        let hostingView = NSHostingView(rootView: DuplicateStructureDialog(
            model: model,
            onConfirm: { [weak self] destURL, substitution in
                self?.dismiss()
                self?.onComplete?(destURL, substitution)
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        ))
        window.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(from parentWindow: NSWindow) {
        guard let window else { return }
        parentWindow.beginSheet(window, completionHandler: nil)
    }

    private func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}
