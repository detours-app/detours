import Observation
import SwiftUI

@Observable
final class DuplicateStructureModel {
    let sourceURL: URL
    var destinationPath: String
    var substituteYears: Bool
    var fromYear: String
    var toYear: String

    var isValid: Bool {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Check for invalid characters
        if trimmed.contains(":") || trimmed.contains("\0") {
            return false
        }

        // Check parent directory exists
        let destURL = URL(fileURLWithPath: trimmed)
        let parentPath = destURL.deletingLastPathComponent().path
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: parentPath, isDirectory: &isDir) && isDir.boolValue
    }

    var validationError: String? {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Destination path cannot be empty"
        }
        if trimmed.contains(":") || trimmed.contains("\0") {
            return "Path contains invalid characters"
        }
        let destURL = URL(fileURLWithPath: trimmed)
        let parentPath = destURL.deletingLastPathComponent().path
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: parentPath, isDirectory: &isDir) || !isDir.boolValue {
            return "Parent directory does not exist"
        }
        return nil
    }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL

        // Detect year in folder name
        // Pattern matches 4-digit years (1900-2099) that aren't surrounded by other digits
        let folderName = sourceURL.lastPathComponent
        let yearPattern = #"(?<!\d)(19|20)\d{2}(?!\d)"#
        let regex = try? NSRegularExpression(pattern: yearPattern)
        let range = NSRange(folderName.startIndex..., in: folderName)

        if let match = regex?.firstMatch(in: folderName, range: range),
           let matchRange = Range(match.range, in: folderName) {
            let detectedYear = String(folderName[matchRange])
            let nextYear: String
            if let yearInt = Int(detectedYear) {
                nextYear = String(yearInt + 1)
            } else {
                nextYear = detectedYear
            }

            self.fromYear = detectedYear
            self.toYear = nextYear
            self.substituteYears = true

            // Default destination: sibling folder with year incremented
            let newFolderName = folderName.replacingOccurrences(of: detectedYear, with: nextYear)
            let siblingURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newFolderName)
            self.destinationPath = siblingURL.path
        } else {
            self.fromYear = ""
            self.toYear = ""
            self.substituteYears = false

            // Default destination: sibling with " copy" suffix
            let newFolderName = folderName + " copy"
            let siblingURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newFolderName)
            self.destinationPath = siblingURL.path
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

            // Source path (read-only)
            VStack(alignment: .leading, spacing: 4) {
                Text("Source:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(model.sourceURL.path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            // Destination path (editable)
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Destination path", text: $model.destinationPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

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
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Duplicate") {
                    let destURL = URL(fileURLWithPath: model.destinationPath)
                    let substitution: (String, String)? = model.substituteYears && !model.fromYear.isEmpty && !model.toYear.isEmpty
                        ? (model.fromYear, model.toYear)
                        : nil
                    onConfirm(destURL, substitution)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isValid)
            }
        }
        .padding(20)
        .frame(width: 450, height: 280)
    }
}
