import Observation
import SwiftUI

@Observable
final class ProgressModel {
    var progress: FileOperationProgress

    init(progress: FileOperationProgress) {
        self.progress = progress
    }
}

struct OperationProgressView: View {
    @Bindable var model: ProgressModel
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.progress.operation.description)
                .font(.headline)

            if let currentItem = model.progress.currentItem {
                Text(currentItem.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView(value: model.progress.fractionCompleted)
                .progressViewStyle(.linear)

            Text("\(model.progress.completedCount) of \(model.progress.totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel?()
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
