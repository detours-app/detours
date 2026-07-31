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
        guard let frame = parseRect(frameString),
              isFinite(frame),
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
        let parsed = frameStrings.prefix(3).map(parseRect)
        guard parsed.allSatisfy({ $0 != nil }) else { return false }
        let frames = parsed.compactMap { $0 }
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

    /// Fits a window frame inside one screen's visible frame, shrinking before moving.
    ///
    /// The launch sanitizer only accepts or rejects a saved frame, so it cannot help once the
    /// window is open: a pane that demands more width than the screen has, or a display that
    /// gets disconnected, both leave the window wider than the screen with its resize edge out
    /// of reach. Clamping keeps the window recoverable by mouse whatever caused the overshoot.
    static func clampedFrame(
        _ frame: NSRect,
        toVisibleFrame visibleFrame: NSRect,
        minimumSize: NSSize
    ) -> NSRect {
        guard isFinite(frame),
              isFinite(visibleFrame),
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return frame
        }

        var clamped = frame
        clamped.size.width = min(frame.width, max(minimumSize.width, visibleFrame.width))
        clamped.size.height = min(frame.height, max(minimumSize.height, visibleFrame.height))
        clamped.origin.x = clampOrigin(
            frame.origin.x,
            length: clamped.width,
            lowerBound: visibleFrame.minX,
            upperBound: visibleFrame.maxX
        )
        clamped.origin.y = clampOrigin(
            frame.origin.y,
            length: clamped.height,
            lowerBound: visibleFrame.minY,
            upperBound: visibleFrame.maxY
        )
        return clamped
    }

    private static func clampOrigin(
        _ origin: CGFloat,
        length: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        // A window larger than the screen still pins to the screen origin rather than drifting
        // off it, so its title bar stays reachable.
        let maximumOrigin = max(upperBound - length, lowerBound)
        return min(max(origin, lowerBound), maximumOrigin)
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

    /// Parses a rect from AppKit's autosave defaults. AppKit stores window frames as
    /// space-separated `x y w h sx sy sw sh` strings and split-view subview frames as
    /// comma-separated `x, y, w, h, collapsed, collapsed` strings; `NSStringFromRect`
    /// (`{{x, y}, {w, h}}`) is also accepted. Returns nil for unparseable input.
    static func parseRect(_ string: String) -> NSRect? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            let rect = NSRectFromString(trimmed)
            return rect == .zero && trimmed != NSStringFromRect(.zero) ? nil : rect
        }

        let separators = CharacterSet(charactersIn: ", \t")
        let numbers = trimmed
            .components(separatedBy: separators)
            .compactMap { component -> Double? in component.isEmpty ? nil : Double(component) }
        guard numbers.count >= 4 else { return nil }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
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
