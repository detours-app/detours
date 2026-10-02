import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "dock-icon")

/// Shows the chosen Dock icon while Detours runs. The app bundle is never modified,
/// so Finder keeps the default icon and the Dock returns to it after quitting.
@MainActor
final class DockIconManager {
    static let shared = DockIconManager()

    private(set) var appliedChoice: DockIcon?
    private lazy var deepSeaImage = Bundle.main.image(forResource: Self.deepSeaImageName)
    private lazy var deepSeaPixels = deepSeaImage.flatMap { Self.thumbnailPixels($0) }
    private lazy var standardPixels = Self.thumbnailPixels(NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: SettingsManager.settingsDidChange,
            object: nil
        )
    }

    @objc private func handleSettingsChange() {
        apply()
    }

    func apply() {
        let choice = SettingsManager.shared.dockIcon
        guard choice != appliedChoice else { return }
        switch choice {
        case .standard:
            NSApplication.shared.applicationIconImage = nil
        case .deepSea:
            guard let deepSeaImage else {
                logger.error("Bundled Dock icon \(Self.deepSeaImageName, privacy: .public) is missing")
                return
            }
            NSApplication.shared.applicationIconImage = deepSeaImage
        }
        appliedChoice = choice
        logger.info("Dock icon set to \(choice.rawValue, privacy: .public)")
    }

    /// Whether the app icon AppKit reports is nearer the deep-sea image than the bundle's own icon.
    /// AppKit keeps its own re-rendered copy of an image it is given, so small renderings are compared.
    var showsDeepSeaImage: Bool {
        guard let differences = shownImageDifferences else { return false }
        return differences.deepSea < differences.standard
    }

    /// Mean per-channel difference, 0 to 1, between the app icon AppKit reports and each icon it can show
    var shownImageDifferences: (deepSea: Double, standard: Double)? {
        guard let shownImage = NSApplication.shared.applicationIconImage,
              let shown = Self.thumbnailPixels(shownImage),
              let deepSeaPixels,
              let standardPixels else { return nil }
        return (Self.difference(shown, deepSeaPixels), Self.difference(shown, standardPixels))
    }

    private static func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        let total = zip(first, second).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(first.count * 255)
    }

    private static func thumbnailPixels(_ image: NSImage) -> [UInt8]? {
        let side = 16
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap), let data = bitmap.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: data, count: side * side * 4))
    }

    /// Each image is drawn with the tile shape, margin and shadow the system gives the
    /// default icon, which changed in macOS 26.
    private static var deepSeaImageName: String {
        if #available(macOS 26, *) {
            return "DeepSeaDock"
        }
        return "DeepSeaDockPre26"
    }
}
