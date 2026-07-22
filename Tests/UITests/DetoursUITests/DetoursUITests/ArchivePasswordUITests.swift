import AppKit
import XCTest

final class ArchivePasswordUITests: BaseUITest {
    func testCreationControlsFollowSelectedFormat() throws {
        try runQualificationRepetitions(group: "archive") { iteration in
            self.runCreationControlsCycle(iteration: iteration)
        }
    }

    private func runCreationControlsCycle(iteration: Int) {
        selectRow(named: "file1.txt")
        chooseFileMenuItem("Archive...")

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.existsOrWait(timeout: 3), "Archive sheet should open")
        let formatPicker = sheet.popUpButtons["archiveFormatPicker"]
        let passwordToggle = sheet.checkBoxes["archivePasswordToggle"]
        XCTAssertTrue(formatPicker.existsOrWait(timeout: 2))
        XCTAssertTrue(passwordToggle.existsOrWait(timeout: 2))

        if iteration.isMultiple(of: 2) {
            chooseArchiveFormat("sevenZ")
            XCTAssertTrue(passwordToggle.isEnabled, "7Z should enable password encryption")
        }

        let passwordlessFormats = [("tarGz", "TAR.GZ"), ("tarBz2", "TAR.BZ2"), ("tarXz", "TAR.XZ")]
        let passwordlessFormat = passwordlessFormats[(iteration - 1) % passwordlessFormats.count]
        chooseArchiveFormat(passwordlessFormat.0)
        XCTAssertFalse(
            passwordToggle.isEnabled,
            "\(passwordlessFormat.1) should disable password encryption"
        )

        chooseArchiveFormat("zip")
        XCTAssertTrue(passwordToggle.isEnabled, "ZIP should enable password encryption")
        passwordToggle.click()
        let passwordField = sheet.secureTextFields["archivePasswordField"]
        XCTAssertTrue(passwordField.existsOrWait(timeout: 2))
        passwordField.click()

        let limitMessage = sheet.staticTexts["ZIP passwords are limited to 80 UTF-8 bytes"]
        if (iteration - 1).isMultiple(of: 10) {
            pastePassword(String(repeating: "a", count: 81), into: passwordField)
            XCTAssertTrue(limitMessage.existsOrWait(timeout: 2))
            XCTAssertFalse(sheet.buttons["archiveConfirmButton"].isEnabled)
        } else {
            pastePassword("a", into: passwordField)
            XCTAssertFalse(limitMessage.exists)
            XCTAssertTrue(sheet.buttons["archiveConfirmButton"].isEnabled)
        }
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.doesNotExistOrWait(timeout: 2))
    }

    func testWrongPasswordShowsRetrySheet() throws {
        let archiveName = "ui-encrypted.zip"
        let payloadName = "ui-archive-secret.txt"
        let archiveURL = uiTestRootURL.appendingPathComponent(archiveName)
        let payloadURL = uiTestRootURL.appendingPathComponent(payloadName)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: payloadURL)
        }
        try Data("UI archive secret".utf8).write(to: payloadURL)
        try createEncryptedAESZip(archiveURL: archiveURL, payloadName: payloadName, password: "right-password")
        try FileManager.default.removeItem(at: payloadURL)
        pressCharKey("r", modifiers: .command)
        XCTAssertTrue(waitForRow(named: archiveName, timeout: 3))

        selectRow(named: archiveName)
        chooseFileMenuItem("Extract Here")
        XCTAssertTrue(app.staticTexts["Password Required"].waitForExistence(timeout: 3))
        submitExtractionPassword("wrong-password")

        XCTAssertTrue(app.staticTexts["Incorrect Password"].waitForExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertFalse(hasTemporaryExtractionDirectory())

        submitExtractionPassword(String(repeating: "x", count: 81))
        XCTAssertTrue(
            app.staticTexts["ZIP passwords are limited to 80 UTF-8 bytes"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Incorrect Password"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertFalse(hasTemporaryExtractionDirectory())

        submitExtractionPassword("right-password")
        XCTAssertTrue(waitForRow(named: payloadName, timeout: 5))
        XCTAssertEqual(try String(contentsOf: payloadURL, encoding: .utf8), "UI archive secret")
        XCTAssertFalse(hasTemporaryExtractionDirectory())
    }

    private func chooseArchiveFormat(_ identifier: String) {
        let picker = app.sheets.firstMatch.popUpButtons.firstMatch
        picker.click()
        let item = app.descendants(matching: .any)["archiveFormat-\(identifier)"]
        XCTAssertTrue(item.existsOrWait(timeout: 2), "\(identifier) archive format should exist")
        item.click()
    }

    private func pastePassword(_ password: String, into field: XCUIElement) {
        let pasteboard = NSPasteboard.general
        let priorString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let priorString {
                _ = pasteboard.setString(priorString, forType: .string)
            }
        }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(password, forType: .string))
        field.typeKey("v", modifierFlags: .command)
    }

    private func submitExtractionPassword(_ password: String) {
        let field = app.secureTextFields["archiveExtractionPasswordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(password)
        app.buttons["archiveExtractionConfirmButton"].click()
    }

    private func createEncryptedAESZip(archiveURL: URL, payloadName: String, password: String) throws {
        let executable = ["/opt/homebrew/bin/7z", "/opt/homebrew/bin/7zz"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let executable else { throw XCTSkip("7z is unavailable") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = uiTestRootURL
        process.arguments = [
            "a", "-bd", "-y", "-tzip", "-mem=AES256", "-p\(password)",
            archiveURL.path, payloadName,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func hasTemporaryExtractionDirectory() -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: uiTestRootURL.path)) ?? []
        return names.contains { $0.hasPrefix(".detours-extract-") }
    }
}
