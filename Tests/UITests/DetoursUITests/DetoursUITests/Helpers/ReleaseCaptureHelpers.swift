import AppKit
import XCTest

extension BaseUITest {
    /// Window capture preserves the compositor's rounded transparent corners, unlike
    /// an XCUI element screenshot, which includes the desktop behind the window.
    func attachReleaseScreenshot(_ name: String, of element: XCUIElement) throws {
        let runningApp = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.detours.app").first)
        let windows = try XCTUnwrap(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])
        let matchingWindow = windows.first { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32,
                  owner == runningApp.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { return false }
            return abs(width - element.frame.width) < 2 && abs(height - element.frame.height) < 2
        }
        let window = try XCTUnwrap(matchingWindow, "Find the exact visible window for \(name)")
        let windowID = try XCTUnwrap(window[kCGWindowNumber as String] as? Int)
        let destination = uiTestControlRootURL.appendingPathComponent("\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(windowID), destination.path]
        try process.run()
        guard waitForCondition(timeout: 10, { !process.isRunning }) else {
            process.terminate()
            XCTFail("Native window capture did not finish")
            return
        }
        XCTAssertEqual(process.terminationStatus, 0, "Native window capture must succeed")
        let data = try Data(contentsOf: destination)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0, "The window corner must be transparent")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
