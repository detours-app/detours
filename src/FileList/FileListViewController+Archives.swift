import AppKit

extension FileListViewController {
    func archiveSelection() {
        guard !isSharedTopLevelView else { return }
        let locations = selectedLocations
        let displayURLs = locations.map { URL(fileURLWithPath: $0.path) }
        guard !locations.isEmpty else { return }
        guard let window = view.window else { return }

        let controller = ArchiveWindowController(sourceURLs: displayURLs) { [weak self] model in
            guard let self else { return }
            let password = model.includePassword && model.format.supportsPassword && !model.password.isEmpty ? model.password : nil

            Task { @MainActor in
                do {
                    let archiveLocation = try await PaneFileOperationCoordinator.shared.perform(
                        affecting: Set(locations.map { $0.deletingLastPathComponent() })
                    ) {
                        try await FileOperationQueue.shared.archive(
                            items: locations,
                            format: model.format,
                            archiveName: model.archiveName,
                            password: password,
                            undoManager: self.undoManager
                        )
                    }
                    self.reloadCurrentListing(selecting: archiveLocation)
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
        controller.present(from: window)
    }

    func extractSelectedArchive() {
        extractArchives(selectedLocations)
    }

    func extractArchives(_ locations: [Location], password: String? = nil, completed: [Location] = []) {
        guard Self.isExtractableSelection(locations), let archiveLocation = locations.first else { return }
        // The extraction holds the controller for its duration on purpose; the retry
        // callback below outlives it and must not, hence the differing ownership.
        Task { @MainActor [self] in
            do {
                var consumed: Set<Location> = [archiveLocation]
                let extractedLocation = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: [archiveLocation.deletingLastPathComponent()]
                ) {
                    try await FileOperationQueue.shared.extract(
                        archive: archiveLocation,
                        password: password,
                        undoManager: self.undoManager,
                        onRarParts: { consumed.formUnion($0) }
                    )
                }
                let results = completed + [extractedLocation]
                self.refreshSelectingLocations(results)
                self.extractArchives(locations.filter { !consumed.contains($0) }, completed: results)
            } catch FileOperationError.archivePasswordRequired {
                self.promptForArchivePassword(
                    archive: archiveLocation,
                    incorrectPassword: password != nil
                ) { [weak self] enteredPassword in
                    self?.extractArchives(locations, password: enteredPassword, completed: completed)
                }
            } catch FileOperationError.cancelled {
                return
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func promptForArchivePassword(
        archive: Location,
        incorrectPassword: Bool,
        completion: @escaping (String) -> Void
    ) {
        guard let window = view.window else { return }
        ArchivePasswordSheet(
            archive: archive,
            incorrectPassword: incorrectPassword,
            completion: completion
        ).present(from: window)
    }

    private func reloadCurrentListing(selecting location: Location) {
        refreshSelectingLocations([location])
    }

    static func isExtractableArchiveLocation(_ location: Location) -> Bool {
        let url = URL(fileURLWithPath: location.path)
        guard let format = ArchiveFormat.detect(from: url) else { return false }
        switch location {
        case .local:
            return CompressionTools.canExtract(format)
        case .remote:
            return true
        }
    }

    static func isExtractableSelection(_ locations: [Location]) -> Bool {
        guard !locations.isEmpty, locations.allSatisfy(isExtractableArchiveLocation) else { return false }
        return locations.count == 1 || locations.allSatisfy { ArchiveFormat.detect(from: URL(fileURLWithPath: $0.path)) == .rar }
    }
}

@MainActor
private final class ArchivePasswordSheet: NSObject {
    private let archive: Location
    private let completion: (String) -> Void
    private let alert = NSAlert()
    private let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 24))
    private let validationLabel = NSTextField(labelWithString: "")
    private var submittedPassword: String?
    private var retainedSelf: ArchivePasswordSheet?

    init(archive: Location, incorrectPassword: Bool, completion: @escaping (String) -> Void) {
        self.archive = archive
        self.completion = completion
        super.init()

        alert.messageText = incorrectPassword ? "Incorrect Password" : "Password Required"
        alert.informativeText = incorrectPassword
            ? "The password for \"\(archive.lastPathComponent)\" was incorrect. Try again."
            : "\"\(archive.lastPathComponent)\" is password-protected."
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")

        passwordField.placeholderString = "Password"
        passwordField.setAccessibilityIdentifier("archiveExtractionPasswordField")
        validationLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        validationLabel.setAccessibilityIdentifier("archiveExtractionValidation")
        validationLabel.textColor = .systemRed
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.maximumNumberOfLines = 2

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        accessory.addSubview(passwordField)
        accessory.addSubview(validationLabel)
        alert.accessoryView = accessory
    }

    func present(from window: NSWindow) {
        retainedSelf = self
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.retainedSelf = nil }
            guard response == .alertFirstButtonReturn, let password = self.submittedPassword else { return }
            self.completion(password)
        }

        let extractButton = alert.buttons[0]
        extractButton.setAccessibilityIdentifier("archiveExtractionConfirmButton")
        extractButton.target = self
        extractButton.action = #selector(submit)
        alert.window.initialFirstResponder = passwordField
    }

    @objc private func submit() {
        let password = passwordField.stringValue
        guard !password.isEmpty else {
            validationLabel.stringValue = "Enter a password"
            return
        }
        if ArchiveFormat.detect(from: URL(fileURLWithPath: archive.path)) == .zip,
           let message = ArchivePasswordValidation.errorMessage(for: password, format: .zip) {
            validationLabel.stringValue = message
            return
        }

        submittedPassword = password
        guard let parent = alert.window.sheetParent else { return }
        parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
    }
}
