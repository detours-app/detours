import AppKit
import SwiftUI

private final class DuplicateStructureSheetWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

final class DuplicateStructureWindowController: NSWindowController {
    private let model: DuplicateStructureModel
    private var onComplete: ((URL, (String, String)?) -> Void)?
    private var uiTestPollingTask: Task<Void, Never>?
    private var uiTestPresentationID: String?
    private var uiTestDismissalID: String?
    private var lastUITestActionID: String?

    init(sourceURL: URL, completion: @escaping (URL, (String, String)?) -> Void) {
        self.model = DuplicateStructureModel(sourceURL: sourceURL)
        self.onComplete = completion

        let window = DuplicateStructureSheetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Duplicate Structure"

        super.init(window: window)

        window.onCancel = { [weak self] in
            self?.cancelDuplicate()
        }

        let hostingView = NSHostingView(rootView: DuplicateStructureDialog(
            model: model,
            onConfirm: { [weak self] destURL, substitution in
                self?.confirmDuplicate(destinationURL: destURL, substitution: substitution)
            },
            onCancel: { [weak self] in
                self?.cancelDuplicate()
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
        installUITestHooksIfNeeded()
        parentWindow.beginSheet(window) { [weak self, weak parentWindow] _ in
            // Release when sheet ends
            if let parentWindow {
                objc_setAssociatedObject(parentWindow, "duplicateStructureController", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            self?.acknowledgeUITestDismissalIfNeeded()
            self?.onComplete = nil
        }
    }

    private func installUITestHooksIfNeeded() {
        guard UITestEnvironment.isEnabled else { return }

        let presentationID = UUID().uuidString
        uiTestPresentationID = presentationID
        lastUITestActionID = UITestEnvironment.currentDuplicateStructureAction()?.id

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            UITestEnvironment.writeDuplicateStructurePresented(
                id: presentationID,
                sourceName: model.sourceURL.lastPathComponent,
                folderName: model.folderName
            )
        }

        uiTestPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollUITestAction()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func pollUITestAction() {
        guard let command = UITestEnvironment.currentDuplicateStructureAction(),
              command.id != lastUITestActionID else {
            return
        }

        lastUITestActionID = command.id
        uiTestDismissalID = command.id

        switch command.action {
        case "duplicate":
            confirmDuplicate(destinationURL: model.destinationURL, substitution: yearSubstitution)
        case "cancel":
            cancelDuplicate()
        default:
            break
        }
    }

    private var yearSubstitution: (String, String)? {
        model.substituteYears && !model.fromYear.isEmpty && !model.toYear.isEmpty
            ? (model.fromYear, model.toYear)
            : nil
    }

    private func confirmDuplicate(destinationURL: URL, substitution: (String, String)?) {
        // Capture callback before dismiss (endSheet clears onComplete)
        let callback = onComplete
        dismissSheet()
        callback?(destinationURL, substitution)
    }

    private func cancelDuplicate() {
        dismissSheet()
    }

    private func dismissSheet() {
        guard let window, let parent = window.sheetParent else { return }
        uiTestPollingTask?.cancel()
        uiTestPollingTask = nil
        parent.endSheet(window)
    }

    private func acknowledgeUITestDismissalIfNeeded() {
        guard UITestEnvironment.isEnabled else { return }
        let dismissalID = uiTestDismissalID ?? uiTestPresentationID ?? UUID().uuidString
        UITestEnvironment.writeDuplicateStructureDismissed(id: dismissalID)
    }
}
