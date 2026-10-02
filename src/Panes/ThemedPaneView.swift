import AppKit

// MARK: - Themed Pane View

/// View that draws theme surface color as background
final class ThemedPaneView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupThemeObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupThemeObserver()
    }

    private func setupThemeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ThemeManager.shared.currentTheme.header.setFill()
        bounds.fill()
    }
}
