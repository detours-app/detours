import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "dock-icon")

/// Shows the chosen Dock icon while Detours runs. The app bundle is never modified,
/// so Finder keeps the default icon and the Dock returns to it after quitting.
@MainActor
final class DockIconManager {
    static let shared = DockIconManager()

    private var appliedChoice: DockIcon?

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
            guard let image = Bundle.main.image(forResource: Self.deepSeaImageName) else {
                logger.error("Bundled Dock icon \(Self.deepSeaImageName, privacy: .public) is missing")
                return
            }
            NSApplication.shared.applicationIconImage = image
        }
        appliedChoice = choice
        logger.info("Dock icon set to \(choice.rawValue, privacy: .public)")
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
