import AppKit
import XCTest
@testable import Detours

final class HousekeepingTests: XCTestCase {

    // MARK: - Hidden Files Toggle

    @MainActor
    func testShowHiddenFilesDefaultsToFalse() {
        let dataSource = FileListDataSource()
        XCTAssertFalse(dataSource.showHiddenFiles)
    }

    @MainActor
    func testShowHiddenFilesCanBeToggled() {
        let dataSource = FileListDataSource()
        dataSource.showHiddenFiles = true
        XCTAssertTrue(dataSource.showHiddenFiles)
        dataSource.showHiddenFiles = false
        XCTAssertFalse(dataSource.showHiddenFiles)
    }

    @MainActor
    private func loadDirectoryAndWait(_ dataSource: FileListDataSource, at url: URL) async {
        await withCheckedContinuation { continuation in
            dataSource.onLoadCompleted = { _ in
                dataSource.onLoadCompleted = nil
                continuation.resume()
            }
            dataSource.loadDirectory(url)
        }
    }

    @MainActor
    func testLoadDirectorySkipsHiddenFilesWhenFalse() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create visible and hidden files
        try "visible".write(to: tempDir.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: tempDir.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)

        let dataSource = FileListDataSource()
        dataSource.showHiddenFiles = false
        await loadDirectoryAndWait(dataSource, at: tempDir)

        XCTAssertEqual(dataSource.items.count, 1)
        XCTAssertEqual(dataSource.items.first?.name, "visible.txt")
    }

    @MainActor
    func testLoadDirectoryIncludesHiddenFilesWhenTrue() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create visible and hidden files
        try "visible".write(to: tempDir.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: tempDir.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)

        let dataSource = FileListDataSource()
        dataSource.showHiddenFiles = true
        await loadDirectoryAndWait(dataSource, at: tempDir)

        XCTAssertEqual(dataSource.items.count, 2)
        let names = dataSource.items.map { $0.name }.sorted()
        XCTAssertEqual(names, [".hidden.txt", "visible.txt"])
    }

    // MARK: - Menu Items

    @MainActor
    func testGoMenuHasKeyboardShortcuts() {
        setupMainMenu(target: AppDelegate())
        let goMenu = NSApp.mainMenu?.item(withTitle: "Go")?.submenu

        let back = goMenu?.item(withTitle: "Back")
        XCTAssertEqual(back?.action, #selector(FileListViewController.goBack(_:)))
        XCTAssertEqual(back?.keyEquivalent, String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        XCTAssertEqual(back?.keyEquivalentModifierMask, .command)

        let forward = goMenu?.item(withTitle: "Forward")
        XCTAssertEqual(forward?.action, #selector(FileListViewController.goForward(_:)))
        XCTAssertEqual(forward?.keyEquivalent, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        XCTAssertEqual(forward?.keyEquivalentModifierMask, .command)

        let enclosing = goMenu?.item(withTitle: "Enclosing Folder")
        XCTAssertEqual(enclosing?.action, #selector(FileListViewController.goUp(_:)))
        XCTAssertEqual(enclosing?.keyEquivalent, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertEqual(enclosing?.keyEquivalentModifierMask, .command)

        let refresh = goMenu?.item(withTitle: "Refresh")
        XCTAssertEqual(refresh?.action, #selector(AppDelegate.refresh(_:)))
        XCTAssertFalse(refresh?.keyEquivalent.isEmpty ?? true)
    }

    @MainActor
    func testFileMenuHasRevealInFinder() {
        setupMainMenu(target: AppDelegate())
        let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Reveal in Finder")

        XCTAssertNotNil(item)
        XCTAssertEqual(item?.action, #selector(FileListViewController.showInFinder(_:)))
        XCTAssertNotNil(item?.image)
    }

    @MainActor
    func testViewMenuHasToggleHiddenFiles() {
        setupMainMenu(target: AppDelegate())
        let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Toggle Hidden Files")

        XCTAssertNotNil(item)
        XCTAssertEqual(item?.action, #selector(AppDelegate.toggleHiddenFiles(_:)))
        XCTAssertFalse(item?.keyEquivalent.isEmpty ?? true)
    }

    @MainActor
    func testRemoteHostAndNetworkShareActionsStayInFileMenuOnly() {
        let appDelegate = AppDelegate()
        setupMainMenu(target: appDelegate)

        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = mainMenu.item(withTitle: "File")?.submenu,
              let goMenu = mainMenu.item(withTitle: "Go")?.submenu else {
            XCTFail("Main menu should include File and Go menus")
            return
        }

        XCTAssertNotNil(fileMenu.item(withTitle: "Add Remote Host..."))
        XCTAssertNotNil(fileMenu.item(withTitle: "Connect to Network Share..."))
        XCTAssertNil(goMenu.item(withTitle: "Add Remote Host..."))
        XCTAssertNil(goMenu.item(withTitle: "Connect to Network Share..."))
    }

    // MARK: - About Panel

    func testAboutPanelVersion() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let bundleURL = temp.appendingPathComponent("Versioned.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.detours.tests.versioned",
            "CFBundleShortVersionString": "9.8.7",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: bundleURL.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertEqual(AppDelegate.aboutApplicationVersion(bundle: bundle), "9.8.7")
    }
}
