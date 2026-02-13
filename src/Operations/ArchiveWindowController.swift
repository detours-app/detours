import AppKit
import SwiftUI

final class ArchiveWindowController: NSWindowController {
    private let model: ArchiveModel
    private var onComplete: ((ArchiveModel) -> Void)?

    init(sourceURLs: [URL], completion: @escaping (ArchiveModel) -> Void) {
        self.model = ArchiveModel(sourceURLs: sourceURLs)
        self.onComplete = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Archive"

        super.init(window: window)

        let hostingView = NSHostingView(rootView: ArchiveDialog(
            model: model,
            onConfirm: { [weak self] confirmedModel in
                guard let self else { return }
                let callback = self.onComplete
                self.dismissSheet()
                callback?(confirmedModel)
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
        objc_setAssociatedObject(parentWindow, "archiveController", self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parentWindow.beginSheet(window) { [weak self, weak parentWindow] _ in
            if let parentWindow {
                objc_setAssociatedObject(parentWindow, "archiveController", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            self?.onComplete = nil
        }
    }

    private func dismissSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
