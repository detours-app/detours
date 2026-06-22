import Foundation

enum UITestEnvironment {
    static var isEnabled: Bool {
        guard let root = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_ROOT"] else {
            return false
        }
        return !root.isEmpty
    }

    static var rootDirectory: URL? {
        guard let root = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_ROOT"], !root.isEmpty else {
            return nil
        }

        let url: URL
        if root.hasPrefix("/") {
            url = URL(fileURLWithPath: root)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(root)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return url
    }
}
