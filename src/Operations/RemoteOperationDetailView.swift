import AppKit
import Observation
import RemoteOperationSupport
import SwiftUI

@MainActor @Observable
final class RemoteResultModel {
    var presentation: RemoteOperationPresentation
    var busy = false
    var error: String?

    init(_ presentation: RemoteOperationPresentation) { self.presentation = presentation }

    func update(_ next: RemoteOperationPresentation) {
        guard next.id == presentation.id, next.snapshot.revision >= presentation.snapshot.revision else { return }
        presentation = next
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch {
                if let filesystem = error as? OperationFilesystemError,
                   filesystem == .identityChanged || filesystem == .unexpectedContents {
                    self.error = "The recorded item changed or its original name is occupied. Review the files before restoring."
                } else { self.error = RemoteOperationError.reason(for: error) }
            }
        }
    }
}

struct RemoteOperationDetailView: View {
    @Bindable var model: RemoteResultModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Operation Details")
                .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 14, weight: .semibold)))
            Text(model.presentation.summary).accessibilityIdentifier("remoteOperationSummary")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.presentation.selections, id: \.intent.id) { selection in
                        if selection.retainedSource, let source = selection.intent.sources.first,
                           let destination = selection.intent.destination {
                            Text("Copied to \(RemoteOperationPresentation.path(destination)). The original is still at \(RemoteOperationPresentation.path(source)).")
                        }
                    }
                    ForEach(model.presentation.snapshot.items, id: \.identity.id) { item in
                        itemDetails(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            if let error = model.error { Text(error).foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary)) }
            HStack {
                if model.presentation.needsCheck {
                    Button("Check Result") {
                        model.perform { try await FileOperationQueue.shared.checkRemoteResult(model.presentation.id) }
                    }.accessibilityIdentifier("checkRemoteResult")
                }
                if model.presentation.canUndo {
                    Button("Undo Confirmed Changes") {
                        model.perform {
                            try await FileOperationQueue.shared.undoAcceptedOperation(model.presentation.snapshot)
                        }
                    }.accessibilityIdentifier("undoRemoteResult")
                }
                Spacer()
                if model.presentation.active {
                    Button(model.presentation.canCancel ? "Cancel Operation" : "Cancelling...") {
                        model.perform { try await FileOperationQueue.shared.cancelRemoteResult(model.presentation.id) }
                    }
                    .disabled(!model.presentation.canCancel)
                    .accessibilityIdentifier("cancelRemoteResult")
                }
            }
            .controlSize(.small)
            .disabled(model.busy)
        }
        .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 11)))
        .padding(16)
        .frame(width: 480, height: 400)
    }

    @ViewBuilder
    private func itemDetails(_ item: RemoteOperationStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.presentation.hostName(item)).fontWeight(.semibold).accessibilityIdentifier("remoteOperationHost")
            ForEach(item.result.intent.sources, id: \.self) { source in
                Text("Source: \(RemoteOperationPresentation.path(source))")
            }
            if let destination = item.result.intent.destination {
                Text("Destination: \(RemoteOperationPresentation.path(destination))")
            }
            Text(model.presentation.status(item))
            ForEach(item.result.receipt?.effects ?? [], id: \.location) { effect in
                Text("Confirmed location: \(RemoteOperationPresentation.path(effect.location))")
            }
            ForEach(Array((item.result.receipt?.recovery ?? []).enumerated()), id: \.offset) { _, retained in
                if let location = retained.knownLocation {
                    Text("\(retained.purpose == .scratch ? "Temporary files" : "Retained files"): \(RemoteOperationPresentation.path(location))")
                } else {
                    Text("Recovery location could not be confirmed.")
                    ForEach(retained.possibleLocations, id: \.self) { location in
                        Text("Possible location: \(RemoteOperationPresentation.path(location))")
                    }
                }
            }
            if RemoteOperationCoordinator.canRestoreOriginal(item), !model.presentation.active {
                Button("Restore Original") {
                    model.perform { try await FileOperationQueue.shared.restoreAcceptedOriginal(item) }
                }
                .controlSize(.small)
                .disabled(model.busy)
                .accessibilityIdentifier("restoreRemoteOriginal")
            }
        }
    }
}
