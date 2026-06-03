import SwiftUI

enum RemoteDeployStep: String, CaseIterable, Identifiable, Sendable {
    case connecting = "Connecting"
    case checkingArchitecture = "Checking host architecture"
    case installingHelper = "Installing helper"
    case startingHelper = "Starting helper"
    case done = "Done"

    var id: String { rawValue }
}

@Observable
final class DeploySheetModel {
    let hostName: String
    var completedSteps: Set<RemoteDeployStep> = []
    var currentStep: RemoteDeployStep = .connecting
    var isCancelling = false

    init(hostName: String) {
        self.hostName = hostName
    }

    func markComplete(_ step: RemoteDeployStep) {
        completedSteps.insert(step)
        currentStep = nextStep(after: step) ?? step
    }

    private func nextStep(after step: RemoteDeployStep) -> RemoteDeployStep? {
        let steps = RemoteDeployStep.allCases
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }
}

struct DeploySheetView: View {
    @Bindable var model: DeploySheetModel
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hostName)
                        .font(.headline)
                    Text("Preparing remote helper")
                        .font(.subheadline)
                        .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                }

                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                ForEach(RemoteDeployStep.allCases) { step in
                    HStack(spacing: 10) {
                        Image(systemName: iconName(for: step))
                            .foregroundStyle(iconColor(for: step))
                            .frame(width: 18)
                        Text(step.rawValue)
                            .foregroundStyle(textColor(for: step))
                        Spacer()
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    model.isCancelling = true
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.completedSteps.contains(.done))
            }
        }
        .padding(20)
        .frame(width: 380, height: 300)
    }

    private func iconName(for step: RemoteDeployStep) -> String {
        if model.completedSteps.contains(step) {
            return "checkmark.circle.fill"
        }
        if model.currentStep == step {
            return "circle.dotted"
        }
        return "circle"
    }

    private func iconColor(for step: RemoteDeployStep) -> Color {
        if model.completedSteps.contains(step) {
            return .green
        }
        if model.currentStep == step {
            return .yellow
        }
        return Color(ThemeManager.shared.currentTheme.textTertiary)
    }

    private func textColor(for step: RemoteDeployStep) -> Color {
        if model.completedSteps.contains(step) || model.currentStep == step {
            return Color(ThemeManager.shared.currentTheme.textPrimary)
        }
        return Color(ThemeManager.shared.currentTheme.textSecondary)
    }
}
