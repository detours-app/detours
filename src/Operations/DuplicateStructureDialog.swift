import Observation
import SwiftUI

@Observable
final class DuplicateStructureModel {
    let sourceURL: URL
    let parentDirectory: URL
    var folderName: String
    var substituteYears: Bool
    var fromYear: String
    var toYear: String

    var destinationURL: URL {
        parentDirectory.appendingPathComponent(folderName)
    }

    var isValid: Bool {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Check for invalid characters
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.contains("\0") {
            return false
        }

        return true
    }

    var validationError: String? {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Folder name cannot be empty"
        }
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.contains("\0") {
            return "Name contains invalid characters"
        }
        return nil
    }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        self.parentDirectory = sourceURL.deletingLastPathComponent()

        // Detect year in folder name
        // Pattern matches 4-digit years (1900-2099) that aren't surrounded by other digits
        let sourceName = sourceURL.lastPathComponent
        let yearPattern = #"(?<!\d)(19|20)\d{2}(?!\d)"#
        let regex = try? NSRegularExpression(pattern: yearPattern)
        let range = NSRange(sourceName.startIndex..., in: sourceName)

        if let match = regex?.firstMatch(in: sourceName, range: range),
           let matchRange = Range(match.range, in: sourceName) {
            let detectedYear = String(sourceName[matchRange])
            let nextYear: String
            if let yearInt = Int(detectedYear) {
                nextYear = String(yearInt + 1)
            } else {
                nextYear = detectedYear
            }

            self.fromYear = detectedYear
            self.toYear = nextYear
            self.substituteYears = true

            // Default: folder name with year incremented
            self.folderName = sourceName.replacingOccurrences(of: detectedYear, with: nextYear)
        } else {
            self.fromYear = ""
            self.toYear = ""
            self.substituteYears = false

            // Default: folder name with " copy" suffix
            self.folderName = sourceName + " copy"
        }
    }
}

struct DuplicateStructureDialog: View {
    @Bindable var model: DuplicateStructureModel
    var onConfirm: (URL, (String, String)?) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duplicate Folder Structure")
                .font(.headline)

            // Source folder (read-only)
            VStack(alignment: .leading, spacing: 4) {
                Text("Source:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(model.sourceURL.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
            }

            // Parent directory (read-only, for context)
            VStack(alignment: .leading, spacing: 4) {
                Text("Location:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(model.parentDirectory.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // New folder name (editable)
            VStack(alignment: .leading, spacing: 4) {
                Text("New folder name:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Folder name", text: $model.folderName)
                    .textFieldStyle(.roundedBorder)

                if let error = model.validationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // Year substitution
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Substitute years in folder names", isOn: $model.substituteYears)
                    .toggleStyle(.checkbox)

                if model.substituteYears {
                    HStack(spacing: 8) {
                        TextField("From", text: $model.fromYear)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("→")
                            .foregroundStyle(.secondary)
                        TextField("To", text: $model.toYear)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                    .padding(.leading, 20)
                }
            }

            Spacer()
                .frame(height: 8)

            // Buttons
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Duplicate") {
                    let substitution: (String, String)? = model.substituteYears && !model.fromYear.isEmpty && !model.toYear.isEmpty
                        ? (model.fromYear, model.toYear)
                        : nil
                    onConfirm(model.destinationURL, substitution)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isValid)
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
    }
}
