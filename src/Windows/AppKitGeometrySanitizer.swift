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

    /// Moves the saved window frame back onto a screen when it would otherwise open out
    /// of reach, and never changes its size.
    ///
    /// The window's size belongs to whoever set it. Shrinking it to fit a smaller screen
    /// loses that size permanently, because the shrunk frame is what gets saved; the
    /// window is resizable, so a size too big for the current screen is the user's to
    /// correct. Position is different: a window with no title bar on any screen cannot
    /// be reached at all, so it is pulled back far enough to grab.
    static func sanitizeWindowFrame(
        defaults: UserDefaults,
        autosaveName: String,
        visibleScreenFrames: [NSRect],
        minimumSize: NSSize
    ) {
        let key = windowFrameKey(autosaveName: autosaveName)
        guard let value = defaults.string(forKey: key) else { return }

        guard let frame = parseRect(value), isFinite(frame), frame.width > 0, frame.height > 0 else {
            defaults.removeObject(forKey: key)
            return
        }

        let usableScreens = visibleScreenFrames.filter {
            isFinite($0) && $0.width > 0 && $0.height > 0
        }
        // With no screen to measure against there is nothing to correct, and the
        // saved frame is still the best guess available.
        guard let screenFrame = screenFrame(hosting: frame, among: usableScreens) else { return }

        let fitted = reachableFrame(frame, onVisibleFrame: screenFrame)
        guard fitted != frame else { return }

        defaults.set(rewritten(value, withFrame: fitted), forKey: key)
    }

    /// Picks the screen the saved frame belongs to: the one it overlaps most, or the
    /// first available screen when the frame sits entirely off every screen, which is
    /// what a disconnected display leaves behind.
    private static func screenFrame(hosting frame: NSRect, among screenFrames: [NSRect]) -> NSRect? {
        let overlapping = screenFrames.max { left, right in
            area(left.intersection(frame)) < area(right.intersection(frame))
        }
        guard let overlapping, area(overlapping.intersection(frame)) > 0 else {
            return screenFrames.first
        }
        return overlapping
    }

    private static func area(_ rect: NSRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }

    /// Writes a corrected frame back in the format the value already used. AppKit's own
    /// `x y w h sx sy sw sh` string keeps its trailing screen record, because that is
    /// what AppKit reads to decide whether the display has changed since the save.
    private static func rewritten(_ value: String, withFrame frame: NSRect) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("{") else { return NSStringFromRect(frame) }

        let numbers = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ", \t"))
            .filter { !$0.isEmpty }
        let head = [frame.origin.x, frame.origin.y, frame.width, frame.height]
            .map { String(format: "%g", $0) }
        return (head + numbers.dropFirst(4)).joined(separator: " ") + " "
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

    /// Moves a window frame so it can be grabbed on the given screen, without ever
    /// changing its size.
    ///
    /// A window wider or taller than the screen is left that way: it is resizable, and
    /// shrinking it here would overwrite the size the user chose with whatever the
    /// smallest screen of the moment allows. Only the origin moves, and only far enough
    /// that the window overlaps the visible frame and its title bar is on it.
    static func reachableFrame(_ frame: NSRect, onVisibleFrame visibleFrame: NSRect) -> NSRect {
        guard isFinite(frame),
              isFinite(visibleFrame),
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return frame
        }

        var moved = frame
        moved.origin.x = reachableOrigin(
            frame.origin.x,
            length: frame.width,
            lowerBound: visibleFrame.minX,
            upperBound: visibleFrame.maxX
        )
        moved.origin.y = reachableOrigin(
            frame.origin.y,
            length: frame.height,
            lowerBound: visibleFrame.minY,
            upperBound: visibleFrame.maxY
        )
        return moved
    }

    private static func reachableOrigin(
        _ origin: CGFloat,
        length: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        // A window longer than the screen pins to the screen origin and overhangs the far
        // edge, rather than being cut down to fit.
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
