import AppKit
import SwiftUI

final class DuplicateStructureWindowController: NSWindowController {
    private let model: DuplicateStructureModel
    private var onComplete: ((URL, (String, String)?) -> Void)?

    init(sourceURL: URL, completion: @escaping (URL, (String, String)?) -> Void) {
        self.model = DuplicateStructureModel(sourceURL: sourceURL)
        self.onComplete = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
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
                guard let self else { return }
                // Capture callback before dismiss (endSheet clears onComplete)
                let callback = self.onComplete
                self.dismissSheet()
                callback?(destURL, substitution)
            },
            onCancel: { [weak self] in
                self?.dismissSheet()
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
        // Retain self while sheet is presented
        objc_setAssociatedObject(parentWindow, "duplicateStructureController", self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parentWindow.beginSheet(window) { [weak self, weak parentWindow] _ in
            // Release when sheet ends
            if let parentWindow {
                objc_setAssociatedObject(parentWindow, "duplicateStructureController", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            self?.onComplete = nil
        }
    }

    private func dismissSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
