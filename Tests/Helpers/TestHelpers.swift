import AppKit
import QualificationSupport
@testable import Detours

func createTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory
    let url = base.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    return url
}

@discardableResult
func createTestFile(in directory: URL, name: String, content: String = "test") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.data(using: .utf8)?.write(to: url)
    return url
}

@discardableResult
func createTestFolder(in directory: URL, name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
    return url
}

func cleanupTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

func waitForFile(at url: URL, exists: Bool, timeout: TimeInterval = 2.0) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) == exists {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return FileManager.default.fileExists(atPath: url.path) == exists
}

@MainActor
func resetSettingsForTests() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "Detours.Settings")

    let manager = SettingsManager.shared
    let defaultsSettings = Settings()

    manager.restoreSession = defaultsSettings.restoreSession
    manager.showHiddenByDefault = defaultsSettings.showHiddenByDefault
    manager.searchIncludesHidden = defaultsSettings.searchIncludesHidden
    manager.theme = defaultsSettings.theme
    manager.fontSize = defaultsSettings.fontSize
    manager.fileListRowDensity = defaultsSettings.fileListRowDensity
    manager.fileListBanding = defaultsSettings.fileListBanding
    manager.dockIcon = defaultsSettings.dockIcon
    manager.dateFormatCurrentYear = defaultsSettings.dateFormatCurrentYear
    manager.dateFormatOtherYears = defaultsSettings.dateFormatOtherYears
    manager.showStatusBar = defaultsSettings.showStatusBar
    manager.folderExpansionEnabled = defaultsSettings.folderExpansionEnabled
    manager.foldersOnTop = defaultsSettings.foldersOnTop
    manager.sidebarVisible = defaultsSettings.sidebarVisible
    manager.favorites = defaultsSettings.favorites
    manager.gitStatusEnabled = defaultsSettings.gitStatusEnabled
    manager.clearAllCustomShortcuts()
}

/// Creates a qualification run root under a temporary parent.
///
/// The workflows operate on a run root, which carries a descriptor the
/// machinery reads back and validates; a bare temporary directory is not one.
/// This builds a real root so the workflows run wherever they are invoked, not
/// only where the qualification runner has mounted its volumes.
@MainActor
func makeTemporaryQualificationRoot() throws -> (root: URL, parent: URL) {
    // Not under the temporary directory: that lives below /var, which macOS
    // presents as both /var and /private/var, and the run-root guard wants the
    // real one while the app standardises paths back to the short one. A root
    // in the caches directory has no such double identity.
    let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/DetoursQualificationTests", isDirectory: true)
    let parent = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let descriptor = try QualificationRunRootGuard().create(provider: .local, allowlistedParent: parent)
    return (URL(fileURLWithPath: descriptor.rootPath, isDirectory: true), parent)
}

extension Theme {
    /// Quiet Pro light tokens with the Detours accent, for tests that need a fixed theme
    static var light: Theme { resolve(isDark: false, increaseContrast: false, accent: .detours) }

    /// Quiet Pro dark tokens with the Detours accent, for tests that need a fixed theme
    static var dark: Theme { resolve(isDark: true, increaseContrast: false, accent: .detours) }
}
