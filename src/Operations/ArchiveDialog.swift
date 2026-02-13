import Observation
import SwiftUI

@Observable
final class ArchiveModel {
    let sourceURLs: [URL]
    let parentDirectory: URL
    var archiveName: String
    var format: ArchiveFormat
    var includePassword: Bool = false
    var password: String = ""

    var isValid: Bool {
        let trimmed = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.contains("\0") {
            return false
        }
        if !CompressionTools.isFormatAvailable(format) {
            return false
        }
        return true
    }

    var validationError: String? {
        let trimmed = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Archive name cannot be empty"
        }
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.contains("\0") {
            return "Name contains invalid characters"
        }
        if !CompressionTools.isFormatAvailable(format) {
            if let tool = CompressionTools.unavailableToolName(for: format) {
                return "\(tool) is not installed"
            }
        }
        return nil
    }

    var fullArchiveName: String {
        let trimmed = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed).\(format.fileExtension)"
    }

    var destinationURL: URL {
        parentDirectory.appendingPathComponent(fullArchiveName)
    }

    init(sourceURLs: [URL]) {
        self.sourceURLs = sourceURLs
        self.parentDirectory = sourceURLs.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")

        // Default archive name
        if sourceURLs.count == 1 {
            let url = sourceURLs[0]
            if url.hasDirectoryPath {
                self.archiveName = url.lastPathComponent
            } else {
                self.archiveName = url.deletingPathExtension().lastPathComponent
            }
        } else {
            let parent = sourceURLs.first?.deletingLastPathComponent().lastPathComponent ?? "Archive"
            self.archiveName = parent
        }

        // Restore last-used format
        if let savedFormat = UserDefaults.standard.string(forKey: "Detours.LastArchiveFormat"),
           let restored = ArchiveFormat(rawValue: savedFormat) {
            self.format = restored
        } else {
            self.format = .zip
        }
    }
}

struct ArchiveDialog: View {
    @Bindable var model: ArchiveModel
    var onConfirm: (ArchiveModel) -> Void
    var onCancel: () -> Void

    private let themeFontName = ThemeManager.shared.currentTheme.fontName
    private let themeFontSize = ThemeManager.shared.fontSize

    private var titleFont: Font {
        .system(size: themeFontSize + 2, weight: .semibold)
    }

    private var labelFont: Font {
        .system(size: themeFontSize, weight: .regular)
    }

    private var monoFont: Font {
        .system(size: themeFontSize, design: .monospaced)
    }

    private var smallFont: Font {
        .system(size: themeFontSize, weight: .regular)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Archive")
                .font(titleFont)

            // Source info
            VStack(alignment: .leading, spacing: 4) {
                Text("Items:")
                    .font(labelFont)
                    .foregroundStyle(.secondary)
                if model.sourceURLs.count == 1 {
                    Text(model.sourceURLs[0].lastPathComponent)
                        .font(monoFont)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("\(model.sourceURLs.count) items selected")
                        .font(monoFont)
                }
            }

            // Archive name
            VStack(alignment: .leading, spacing: 4) {
                Text("Archive name:")
                    .font(labelFont)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("Archive name", text: $model.archiveName)
                        .textFieldStyle(.roundedBorder)
                        .font(monoFont)
                    Text(".\(model.format.fileExtension)")
                        .foregroundStyle(.secondary)
                        .font(monoFont)
                }

                if let error = model.validationError {
                    Text(error)
                        .font(smallFont)
                        .foregroundStyle(.red)
                }
            }

            // Format picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Format:")
                    .font(labelFont)
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.format) {
                    ForEach(ArchiveFormat.allCases, id: \.self) { format in
                        if CompressionTools.isFormatAvailable(format) {
                            Text(format.displayName).tag(format)
                        } else {
                            Text("\(format.displayName) (not installed)")
                                .foregroundStyle(.secondary)
                                .tag(format)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: model.format) { _, newValue in
                    if !newValue.supportsPassword {
                        model.includePassword = false
                        model.password = ""
                    }
                }
            }

            // Format info
            Text(model.format.description)
                .font(smallFont)
                .foregroundStyle(.secondary)

            // Password
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Encrypt with password", isOn: $model.includePassword)
                    .toggleStyle(.checkbox)
                    .font(labelFont)
                    .disabled(!model.format.supportsPassword)

                if model.includePassword && model.format.supportsPassword {
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .font(monoFont)
                }
            }

            Spacer()
                .frame(height: 8)

            // Buttons
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Archive") {
                    // Save format preference
                    UserDefaults.standard.set(model.format.rawValue, forKey: "Detours.LastArchiveFormat")
                    onConfirm(model)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isValid)
            }
        }
        .padding(20)
        .frame(width: 440, height: 400)
    }
}
