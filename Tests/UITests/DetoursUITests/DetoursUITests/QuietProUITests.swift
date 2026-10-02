import AppKit
import XCTest

/// Quiet Pro's app-wide appearance, accent and Dock icon, driven through the installed app.
/// The app reports what it applied through the control seam; screenshots prove the pixels follow.
final class QuietProUITests: BaseUITest {
    private let lightName = "NSAppearanceNameAqua"
    private let darkName = "NSAppearanceNameDarkAqua"
    private let previewFileName = "file1.txt"

    func testAppearanceAppliesAppWide() throws {
        let systemAppearance = XCUIDevice.shared.appearance
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.appearance = systemAppearance
        }

        for (choice, dark) in [("Light", false), ("Dark", true)] {
            choosePreference(inPicker: "appearancePicker", option: choice, keepWindowOpen: true)
            try assertWholeAppAppearance(dark: dark, choice: choice)

            try relaunchApp()
            try assertMainWindowAppearance(dark: dark, appAppearance: dark ? darkName : lightName, label: "\(choice) after relaunch")
        }

        choosePreference(inPicker: "appearancePicker", option: "System")
        for (macOSAppearance, dark) in [(XCUIDevice.Appearance.light, false), (.dark, true)] {
            XCUIDevice.shared.appearance = macOSAppearance
            try assertMainWindowAppearance(dark: dark, appAppearance: nil, label: "System with macOS \(dark ? "Dark" : "Light")")
        }
    }

    func testMulticolorUsesDetoursTeal() throws {
        let multicolor = try appAppearanceState()
        XCTAssertTrue(multicolor.usesDetoursAccent, "This test needs Foundry's accent set to Multicolor")
        let dark = multicolor.effectiveAppearance == darkName

        selectRow(named: previewFileName)
        try assertSelection(inRowNamed: previewFileName, fill: dark ? "#14827A" : "#0F766E", label: "Multicolor")

        // Graphite for this launch, read by AppKit the same way as the System Settings value.
        try relaunchApp(arguments: ["-AppleAccentColor", " -1"])
        let graphite = try appAppearanceState()
        XCTAssertFalse(graphite.usesDetoursAccent, "Graphite is a system accent")
        XCTAssertEqual(graphite.effectiveAppearance, multicolor.effectiveAppearance)

        selectRow(named: previewFileName)
        try assertSelection(inRowNamed: previewFileName, fill: dark ? "#696969" : "#808080", label: "Graphite")
    }

    func testDockIconPreference() throws {
        XCTAssertTrue(
            dockIconIs("standard", deepSeaImage: false),
            "The app should start with the default icon; the app reported \(dockIconReport())"
        )

        choosePreference(inPicker: "dockIconPicker", option: "Deep sea")
        XCTAssertTrue(
            waitForCondition(timeout: 3) { self.dockIconIs("deepSea", deepSeaImage: true) },
            "Choosing Deep sea should change the application icon; the app reported \(self.dockIconReport())"
        )

        try relaunchApp()
        XCTAssertTrue(
            waitForCondition(timeout: 5) { self.dockIconIs("deepSea", deepSeaImage: true) },
            "Deep sea should come back after relaunch; the app reported \(self.dockIconReport())"
        )

        choosePreference(inPicker: "dockIconPicker", option: "Default")
        XCTAssertTrue(
            waitForCondition(timeout: 3) { self.dockIconIs("standard", deepSeaImage: false) },
            "Default should restore the application icon; the app reported \(self.dockIconReport())"
        )
    }

    // MARK: - Appearance checks

    /// Preferences is still open from the choice; then the main window, a right-click menu, an alert and a preview.
    /// Menu-bar menus are not checked: macOS draws them in its own appearance whatever the app chooses.
    private func assertWholeAppAppearance(dark: Bool, choice: String) throws {
        let expected = dark ? darkName : lightName
        let preferences = app.windows["Preferences"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 3), "Preferences should be open")
        assertLooks(preferences, dark: dark, "\(choice) Preferences")
        pressCharKey("w", modifiers: .command)
        XCTAssertTrue(preferences.doesNotExistOrWait(timeout: 3), "Preferences should close")

        try assertMainWindowAppearance(dark: dark, appAppearance: expected, label: choice)

        let row = outlineRow(named: previewFileName)
        XCTAssertTrue(row.waitForExistence(timeout: 3), "\(previewFileName) should be listed")
        row.staticTexts[previewFileName].rightClick()
        // Open With is only in the right-click menu, never in the menu bar.
        let contextMenu = app.menus.containing(NSPredicate(format: "title == %@", "Open With")).firstMatch
        XCTAssertTrue(contextMenu.waitForExistence(timeout: 2), "The right-click menu should open")
        assertLooks(contextMenu, dark: dark, "\(choice) right-click menu")
        pressKey(.escape)
        XCTAssertTrue(contextMenu.doesNotExistOrWait(timeout: 2), "The right-click menu should close")

        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        fileMenu.click()
        fileMenu.menuItems["New File"].hover()
        let emptyFile = app.menuItems["Empty File..."]
        XCTAssertTrue(emptyFile.waitForExistence(timeout: 2), "Empty File should be in the New File menu")
        emptyFile.click()
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "New Empty File should show an alert")
        assertLooks(alert, dark: dark, "\(choice) alert")
        try assertEveryWindow(expected, label: "\(choice) with the alert open")
        alert.buttons["Cancel"].click()
        XCTAssertTrue(alert.doesNotExistOrWait(timeout: 3), "The alert should close")

        selectRow(named: previewFileName)
        pressKey(.space)
        let preview = app.windows[previewFileName]
        XCTAssertTrue(preview.waitForExistence(timeout: 15), "The preview should open")
        assertLooks(preview, dark: dark, "\(choice) preview")
        try assertEveryWindow(expected, label: "\(choice) with the preview open")
        pressKey(.escape)
        XCTAssertTrue(preview.doesNotExistOrWait(timeout: 10), "The preview should close")
    }

    private func assertMainWindowAppearance(
        dark: Bool,
        appAppearance: String?,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = dark ? darkName : lightName
        XCTAssertTrue(
            waitForCondition(timeout: 5) { (try? self.appAppearanceState())?.effectiveAppearance == expected },
            "\(label): the app should resolve to \(expected)",
            file: file,
            line: line
        )
        let state = try appAppearanceState()
        XCTAssertEqual(state.appearance, appAppearance, "\(label): app appearance", file: file, line: line)
        try assertEveryWindow(expected, label: label, file: file, line: line)
        assertLooks(app.windows.firstMatch, dark: dark, "\(label) main window", file: file, line: line)
    }

    private func assertEveryWindow(
        _ expected: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let windows = try appAppearanceState().windowAppearances
        XCTAssertFalse(windows.isEmpty, "\(label): the app reported no windows", file: file, line: line)
        for window in windows {
            XCTAssertTrue(window.hasSuffix("=\(expected)"), "\(label): \(window) should be \(expected)", file: file, line: line)
        }
    }

    private func assertLooks(
        _ element: XCUIElement,
        dark: Bool,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let luminance = meanLuminance(element)
        if dark {
            XCTAssertLessThan(luminance, 0.4, "\(label) should look dark; mean luminance \(luminance)", file: file, line: line)
        } else {
            XCTAssertGreaterThan(luminance, 0.6, "\(label) should look light; mean luminance \(luminance)", file: file, line: line)
        }
    }

    private func meanLuminance(_ element: XCUIElement) -> CGFloat {
        guard let tiff = element.screenshot().image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return -1 }
        let stepX = max(1, bitmap.pixelsWide / 48)
        let stepY = max(1, bitmap.pixelsHigh / 48)
        var total: CGFloat = 0
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let pixel = rgb(bitmap.colorAt(x: x, y: y)) else { continue }
                total += 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
                count += 1
            }
        }
        return count > 0 ? total / CGFloat(count) : -1
    }

    // MARK: - Selection checks

    private func assertSelection(inRowNamed name: String, fill expectedHex: String, label: String) throws {
        XCTAssertTrue(
            waitForCondition(timeout: 3) { (try? self.appAppearanceState())?.selectionFill == expectedHex },
            "\(label): the selection fill should be \(expectedHex), was \((try? self.appAppearanceState())?.selectionFill ?? "unreported")"
        )
        let row = outlineRow(named: name)
        XCTAssertTrue(row.waitForExistence(timeout: 3), "\(name) row should exist")
        let tiff = try XCTUnwrap(row.screenshot().image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let scale = CGFloat(bitmap.pixelsWide) / max(row.frame.width, 1)
        // 13 pt in: inside the 10 pt selection inset and before the 8 pt cell padding and icon.
        let drawn = try XCTUnwrap(rgb(bitmap.colorAt(x: Int(13 * scale), y: bitmap.pixelsHigh / 2)), "The screenshot pixel should be RGB")
        let screenSpace = try XCTUnwrap(NSScreen.main?.colorSpace, "The screen's colour space should be known")
        let expected = try XCTUnwrap(rgb(srgbColor(hex: expectedHex)?.usingColorSpace(screenSpace)))
        let difference = zip(drawn, expected).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(
            difference,
            0.03,
            "\(label): the drawn selection read \(format(drawn)); \(expectedHex) on the"
                + " \(screenSpace.localizedName ?? "unnamed") screen is \(format(expected))"
        )
    }

    // MARK: - Screenshot pixels

    /// Screenshot pixels hold the screen's own values. Converting them through the screenshot's
    /// colour tag gave a different, wrong colour on each Foundry run, so expected colours are
    /// converted into the screen's colour space instead.
    private func rgb(_ color: NSColor?) -> [CGFloat]? {
        guard let color, color.numberOfComponents == 4 else { return nil }
        var values = [CGFloat](repeating: 0, count: 4)
        color.getComponents(&values)
        return Array(values.prefix(3))
    }

    private func format(_ components: [CGFloat]) -> String {
        components.map { String(format: "%.3f", Double($0)) }.joined(separator: " ")
    }

    private func srgbColor(hex: String) -> NSColor? {
        guard hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: - App control

    private func dockIconReport() -> String {
        guard let state = try? appAppearanceState() else { return "nothing" }
        let format = { (difference: Double?) in difference.map { String(format: "%.3f", $0) } ?? "none" }
        return "dockIcon=\(state.dockIcon ?? "nil") deepSeaImage=\(state.dockImageIsDeepSea)"
            + " differenceFromDeepSea=\(format(state.dockImageDeepSeaDifference))"
            + " differenceFromDefault=\(format(state.dockImageStandardDifference))"
    }

    private func dockIconIs(_ choice: String, deepSeaImage: Bool) -> Bool {
        guard let state = try? appAppearanceState() else { return false }
        return state.dockIcon == choice && state.dockImageIsDeepSea == deepSeaImage
    }
}
