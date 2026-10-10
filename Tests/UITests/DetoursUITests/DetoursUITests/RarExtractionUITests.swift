import XCTest

final class RarExtractionUITests: BaseUITest {
    private var corpus: URL {
        (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appendingPathComponent("resources/fixtures/rar")
    }

    func testEncryptedMultipartRarRetriesAndUndoes() throws {
        try importArchive("rarfile/rar5-psw.rar")
        openArchive("rar5-psw.rar")
        submitPassword("wrong-password")
        XCTAssertTrue(app.staticTexts["Incorrect Password"].waitForExistence(timeout: 5))
        XCTAssertFalse(exists("rar5-psw"))
        capture("Confirmed wrong RAR password permits retry")
        submitPassword("password")
        try waitForResult("rar5-psw")
        pressCharKey("z", modifiers: .command)
        XCTAssertTrue(waitForCondition(timeout: 5) { !self.exists("rar5-psw") })

        let parts = (1...6).map { String(format: "Rar.EncryptedParts.part%02d.rar", $0) }
        for part in parts { try importArchive("sharpcompress/" + part) }
        openArchive(try XCTUnwrap(parts.last))
        app.buttons["archiveExtractionConfirmButton"].click()
        XCTAssertTrue(app.staticTexts["Enter a password"].waitForExistence(timeout: 2))
        submitPassword("wrong-password")
        let ambiguity = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
            "encrypted RAR data may be damaged", "encrypted RAR data may be damaged"))
        XCTAssertTrue(ambiguity.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Incorrect Password"].exists)
        XCTAssertFalse(exists("Rar.EncryptedParts"))
        try assertNoScratch()
        capture("Encrypted multipart RAR reports ambiguous password or damage")
        app.dialogs.buttons["OK"].click()

        openArchive(try XCTUnwrap(parts.last))
        submitPassword("test")
        try waitForResult("Rar.EncryptedParts")
        for relative in ["exe/test.exe", "jpg/test.jpg", "тест.txt"] {
            var reference = try Data(contentsOf: corpus.appendingPathComponent("references/sharpcompress/" + relative))
            if relative == "тест.txt" {
                reference = Data(try XCTUnwrap(String(data: reference, encoding: .utf8))
                    .replacingOccurrences(of: "\n", with: "\r\n").utf8)
            }
            XCTAssertEqual(try Data(contentsOf: uiTestRootURL.appendingPathComponent("Rar.EncryptedParts/" + relative)), reference)
        }
        capture("Encrypted multipart RAR result selected")
        pressCharKey("z", modifiers: .command)
        XCTAssertTrue(waitForCondition(timeout: 5) { !self.exists("Rar.EncryptedParts") })
        for part in parts {
            XCTAssertEqual(try Data(contentsOf: uiTestRootURL.appendingPathComponent(part)),
                           try Data(contentsOf: corpus.appendingPathComponent("sharpcompress/" + part)))
        }
        try assertNoScratch()
    }

    func testMissingVolumeExplainsFailure() throws {
        for part in [1, 3] { try importArchive("rarfile/rar3-vols.part\(part).rar") }
        selectRow(named: "rar3-vols.part3.rar")
        chooseFileMenuItem("Extract Here")
        let message = app.staticTexts.matching(NSPredicate(format:
            "(label CONTAINS %@ OR value CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)",
            "rar3-vols.part2.rar", "rar3-vols.part2.rar", "Put every part in the same folder", "Put every part in the same folder"))
        XCTAssertTrue(message.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Incorrect Password"].exists)
        XCTAssertFalse(app.secureTextFields["archiveExtractionPasswordField"].exists)
        XCTAssertFalse(exists("vols"))
        try assertNoScratch()
        capture("Missing RAR part names the file and explains recovery")
        app.dialogs.buttons["OK"].click()
        for part in [1, 3] {
            let name = "rar3-vols.part\(part).rar"
            XCTAssertEqual(try Data(contentsOf: uiTestRootURL.appendingPathComponent(name)),
                           try Data(contentsOf: corpus.appendingPathComponent("rarfile/" + name)))
        }
    }

    func testSelectingSeveralPartsExtractsOnce() throws {
        for part in 1...3 { try importArchive("rarfile/rar3-vols.part\(part).rar") }
        try performFixtureMutation(action: "createDirectory", relativePath: "vols")
        try performFixtureMutation(action: "write", relativePath: "vols/occupant.txt", contents: "Keep this file")
        selectRow(named: "rar3-vols.part1.rar")
        XCUIElement.perform(withKeyModifiers: .shift) {
            outlineRow(named: "rar3-vols.part3.rar").staticTexts["rar3-vols.part3.rar"].click()
        }
        XCTAssertEqual(try requestRemotePaneState(pane: "left").selectedLocations.count, 3)
        chooseFileMenuItem("Extract Here")
        let keepBoth = app.dialogs.buttons["Keep Both"]
        XCTAssertTrue(keepBoth.waitForExistence(timeout: 5))
        XCTAssertTrue(app.progressIndicators.matching(identifier: "File operation progress").firstMatch.exists)
        capture("RAR extraction progress while preserving an existing destination")
        keepBoth.click()
        try waitForResult("vols 2")
        XCTAssertFalse(exists("vols 3"))
        XCTAssertEqual(try String(contentsOf: uiTestRootURL.appendingPathComponent("vols/occupant.txt"), encoding: .utf8), "Keep this file")
        XCTAssertEqual(try Data(contentsOf: uiTestRootURL.appendingPathComponent("vols 2/bigfile.txt")).count, 205000)
        XCTAssertEqual(try Data(contentsOf: uiTestRootURL.appendingPathComponent("vols 2/smallfile.txt")).count, 2050)
        capture("Several selected RAR parts produce one selected result")
        pressCharKey("z", modifiers: .command)
        XCTAssertTrue(waitForCondition(timeout: 5) { !self.exists("vols 2") })
        XCTAssertTrue(exists("vols/occupant.txt"))
        for part in 1...3 { XCTAssertTrue(exists("rar3-vols.part\(part).rar")) }
        try assertNoScratch()
    }

    private func importArchive(_ relative: String) throws {
        let source = corpus.appendingPathComponent(relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Required pinned RAR fixture is missing")
        try performFixtureMutation(action: "importFile", relativePath: source.lastPathComponent, contents: source.path)
        pressCharKey("r", modifiers: .command)
        XCTAssertTrue(waitForRow(named: source.lastPathComponent, timeout: 3))
    }

    private func openArchive(_ name: String) {
        selectRow(named: name)
        outlineRow(named: name).staticTexts[name].doubleClick()
        XCTAssertTrue(app.staticTexts["Password Required"].waitForExistence(timeout: 5))
    }

    private func submitPassword(_ password: String) {
        let field = app.secureTextFields["archiveExtractionPasswordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(password)
        app.buttons["archiveExtractionConfirmButton"].click()
    }

    private func waitForResult(_ name: String) throws {
        XCTAssertTrue(waitForRow(named: name, timeout: 8))
        XCTAssertTrue(waitForCondition(timeout: 5) {
            guard let state = try? self.requestRemotePaneState(pane: "left") else { return false }
            return !state.operationRunning && state.operationPendingCount == 0
                && state.selectedLocations == [self.uiTestRootURL.appendingPathComponent(name).path]
        })
        XCTAssertFalse(app.dialogs.buttons["Keep Both"].exists)
        try assertNoScratch()
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: uiTestRootURL.appendingPathComponent(name).path)
    }

    private func assertNoScratch() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: uiTestRootURL.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".detours-extract-") || $0.hasPrefix(".detours-partial-") })
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
