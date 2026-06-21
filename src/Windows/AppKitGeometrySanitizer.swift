import AppKit

enum AppKitGeometrySanitizer {
    static let migrationMarkerKey = "Detours.AppKitGeometryMigration.AppKitV1"
    static let legacySidebarWidthKey = "Detours.SidebarWidth"
    static let legacySplitDividerPositionKey = "Detours.SplitDividerPosition"

    static func preflight(
        defaults: UserDefaults,
        visibleScreenFrames: [NSRect],
        windowAutosaveName: String,
        splitAutosaveName: String,
        minimumWindowSize: NSSize,
        sidebarMinimumWidth: CGFloat = 150,
        paneMinimumWidth: CGFloat = 200
    ) {
        migrateOnce(defaults: defaults, keepingSplitAutosaveName: splitAutosaveName)
        sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: windowAutosaveName,
            visibleScreenFrames: visibleScreenFrames,
            minimumSize: minimumWindowSize
        )
        sanitizeSplitFrames(
            defaults: defaults,
            autosaveName: splitAutosaveName,
            minimumWindowSize: minimumWindowSize,
            sidebarMinimumWidth: sidebarMinimumWidth,
            paneMinimumWidth: paneMinimumWidth
        )
    }

    static func migrateOnce(defaults: UserDefaults, keepingSplitAutosaveName autosaveName: String) {
        guard !defaults.bool(forKey: migrationMarkerKey) else { return }

        defaults.removeObject(forKey: legacySidebarWidthKey)
        defaults.removeObject(forKey: legacySplitDividerPositionKey)

        let currentSplitFramesKey = splitSubviewFramesKey(autosaveName: autosaveName)
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("NSSplitView Subview Frames Detours.") && key != currentSplitFramesKey {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: migrationMarkerKey)
    }

    static func sanitizeWindowFrame(
        defaults: UserDefaults,
        autosaveName: String,
        visibleScreenFrames: [NSRect],
        minimumSize: NSSize
    ) {
        let key = windowFrameKey(autosaveName: autosaveName)
        guard let value = defaults.string(forKey: key) else { return }
        guard isValidWindowFrame(value, visibleScreenFrames: visibleScreenFrames, minimumSize: minimumSize) else {
            defaults.removeObject(forKey: key)
            return
        }
    }

    static func sanitizeSplitFrames(
        defaults: UserDefaults,
        autosaveName: String,
        minimumWindowSize: NSSize,
        sidebarMinimumWidth: CGFloat,
        paneMinimumWidth: CGFloat
    ) {
        let key = splitSubviewFramesKey(autosaveName: autosaveName)
        guard defaults.object(forKey: key) != nil else { return }
        guard let frameStrings = splitFrameStrings(defaults.object(forKey: key)),
              isValidSplitFrames(
                frameStrings,
                minimumWindowSize: minimumWindowSize,
                sidebarMinimumWidth: sidebarMinimumWidth,
                paneMinimumWidth: paneMinimumWidth
              ) else {
            defaults.removeObject(forKey: key)
            return
        }
    }

    static func isValidWindowFrame(
        _ frameString: String,
        visibleScreenFrames: [NSRect],
        minimumSize: NSSize
    ) -> Bool {
        let frame = NSRectFromString(frameString)
        guard isFinite(frame),
              frame.width >= minimumSize.width,
              frame.height >= minimumSize.height,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        return visibleScreenFrames.contains { screenFrame in
            guard isFinite(screenFrame), screenFrame.width > 0, screenFrame.height > 0 else {
                return false
            }
            return screenFrame.contains(frame)
        }
    }

    static func isValidSplitFrames(
        _ frameStrings: [String],
        minimumWindowSize: NSSize,
        sidebarMinimumWidth: CGFloat,
        paneMinimumWidth: CGFloat
    ) -> Bool {
        guard frameStrings.count >= 3 else { return false }
        let frames = frameStrings.prefix(3).map(NSRectFromString)
        guard frames.allSatisfy(isFinite(_:)) else { return false }

        let widths = frames.map(\.width)
        guard widths[0] >= sidebarMinimumWidth,
              widths[1] >= paneMinimumWidth,
              widths[2] >= paneMinimumWidth else {
            return false
        }

        let minimumRequiredWidth = sidebarMinimumWidth + (paneMinimumWidth * 2)
        guard minimumRequiredWidth <= minimumWindowSize.width else { return false }

        let totalSavedWidth = widths.reduce(0, +)
        guard totalSavedWidth >= minimumRequiredWidth,
              totalSavedWidth <= max(minimumWindowSize.width * 4, minimumRequiredWidth) else {
            return false
        }

        return true
    }

    static func windowFrameKey(autosaveName: String) -> String {
        "NSWindow Frame \(autosaveName)"
    }

    static func splitSubviewFramesKey(autosaveName: String) -> String {
        "NSSplitView Subview Frames \(autosaveName)"
    }

    private static func splitFrameStrings(_ value: Any?) -> [String]? {
        switch value {
        case let strings as [String]:
            return strings
        case let array as NSArray:
            return array.compactMap { $0 as? String }
        default:
            return nil
        }
    }

    private static func isFinite(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && !rect.isNull
            && !rect.isInfinite
    }
}
