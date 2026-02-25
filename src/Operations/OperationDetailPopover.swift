import AppKit
import SwiftUI

@MainActor
final class OperationDetailPopover: NSPopover {
    private let model: ProgressModel
    private var onCancel: (() -> Void)?

    init(progress: FileOperationProgress, onCancel: @escaping () -> Void) {
        self.model = ProgressModel(progress: progress)
        self.onCancel = onCancel
        super.init()

        behavior = .semitransient
        let cancelHandler = onCancel
        let hostingView = NSHostingView(rootView: OperationDetailView(model: model) {
            cancelHandler()
        })
        let viewController = NSViewController()
        viewController.view = hostingView
        contentViewController = viewController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ progress: FileOperationProgress) {
        model.progress = progress
    }
}

private struct OperationDetailView: View {
    @Bindable var model: ProgressModel
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.progress.operation.description)
                .font(.headline)
                .lineLimit(2)

            if let currentItem = model.progress.currentItem {
                Text(currentItem.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if model.progress.totalCount > 0 {
                ProgressView(value: model.progress.fractionCompleted)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(model.progress.completedCount) of \(model.progress.totalCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(Int(model.progress.fractionCompleted * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack {
                Spacer()
                Button("Cancel Operation") {
                    onCancel?()
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
