import XCTest

final class ArchivePasswordUITests: BaseUITest {
    func testCreationControlsFollowSelectedFormat() {
        selectRow(named: "file1.txt")
        chooseFileMenuItem("Archive...")

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Archive sheet should open")
        let formatPicker = sheet.popUpButtons["archiveFormatPicker"]
        let passwordToggle = sheet.checkBoxes["archivePasswordToggle"]
        XCTAssertTrue(formatPicker.waitForExistence(timeout: 2))
        XCTAssertTrue(passwordToggle.waitForExistence(timeout: 2))

        chooseArchiveFormat("zip", in: formatPicker)
        XCTAssertTrue(passwordToggle.isEnabled)
        chooseArchiveFormat("sevenZ", in: formatPicker)
        XCTAssertTrue(passwordToggle.isEnabled)
        for (identifier, displayName) in [("tarGz", "TAR.GZ"), ("tarBz2", "TAR.BZ2"), ("tarXz", "TAR.XZ")] {
            chooseArchiveFormat(identifier, in: formatPicker)
            XCTAssertFalse(passwordToggle.isEnabled, "\(displayName) should disable password encryption")
        }

        chooseArchiveFormat("zip", in: formatPicker)
        passwordToggle.click()
        let passwordField = sheet.secureTextFields["archivePasswordField"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 2))
        passwordField.typeText(String(repeating: "a", count: 81))

        let limitMessage = sheet.staticTexts["ZIP passwords are limited to 80 UTF-8 bytes"]
        XCTAssertTrue(limitMessage.waitForExistence(timeout: 2))
        XCTAssertFalse(sheet.buttons["archiveConfirmButton"].isEnabled)
        sheet.buttons["Cancel"].click()
        XCTAssertFalse(sheet.waitForExistence(timeout: 2))
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
        try createEncryptedZip(archiveURL: archiveURL, payloadName: payloadName, password: "right-password")
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

    private func chooseArchiveFormat(_ identifier: String, in picker: XCUIElement) {
        picker.click()
        let item = app.descendants(matching: .any)["archiveFormat-\(identifier)"]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "\(identifier) archive format should exist")
        item.click()
    }

    private func submitExtractionPassword(_ password: String) {
        let field = app.secureTextFields["archiveExtractionPasswordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(password)
        app.buttons["archiveExtractionConfirmButton"].click()
    }

    private func createEncryptedZip(archiveURL: URL, payloadName: String, password: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = uiTestRootURL
        process.arguments = ["-q", "-P", password, archiveURL.path, payloadName]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func hasTemporaryExtractionDirectory() -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: uiTestRootURL.path)) ?? []
        return names.contains { $0.hasPrefix(".detours-extract-") }
    }
}
