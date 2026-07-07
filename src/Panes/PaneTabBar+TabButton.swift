import AppKit
import os.log

// MARK: - Tab Button

final class TabButton: NSView {
    struct Colors {
        let surface: NSColor
        let background: NSColor
        let border: NSColor
        let accent: NSColor
        let textPrimary: NSColor
        let textSecondary: NSColor
    }

    private let iconView = NSImageView()
    private let closeButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isSelected: Bool = false
    private var isHovered: Bool = false
    private var isDropTarget: Bool = false
    private var isPaneActive: Bool = true
    private var trackingArea: NSTrackingArea?
    private let colors: Colors

    private static let iconSize: CGFloat = 16
    private static let leadingPad: CGFloat = 10
    private static let iconTextGap: CGFloat = 6
    private static let trailingPad: CGFloat = 12

    var tabAction: (() -> Void)?
    var closeAction: (() -> Void)?
    var dragAction: ((NSEvent) -> Void)?

    private var mouseDownLocation: NSPoint?

    var idealWidth: CGFloat {
        let textWidth = ceil(titleLabel.intrinsicContentSize.width)
        return Self.leadingPad + Self.iconSize + Self.iconTextGap + textWidth + Self.trailingPad
    }

    init(title: String, symbolName: String, isSelected: Bool, colors: Colors) {
        self.isSelected = isSelected
        self.colors = colors
        super.init(frame: .zero)

        wantsLayer = true

        setupIcon(symbolName)
        setupCloseButton()
        setupTitleLabel(title)

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupIcon(_ symbolName: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = colors.textSecondary
        iconView.imageScaling = .scaleNone

        addSubview(iconView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPad),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    private func setupCloseButton() {
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(config)
        closeButton.imageScaling = .scaleNone
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true

        addSubview(closeButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPad),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Self.iconSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    private func setupTitleLabel(_ title: String) {
        titleLabel.stringValue = title
        titleLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 13, weight: isSelected ? .semibold : .medium)
        titleLabel.lineBreakMode = .byClipping
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconTextGap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingPad),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func closeClicked() {
        closeAction?()
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        titleLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 13, weight: isSelected ? .semibold : .medium)
        updateAppearance()
    }

    func setDropTarget(_ dropTarget: Bool) {
        isDropTarget = dropTarget
        updateAppearance()
    }

    func setPaneActive(_ active: Bool) {
        isPaneActive = active
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = nil
        layer?.cornerRadius = 0

        let backgroundColor = currentBackgroundColor()
        let textColor: NSColor
        if isDropTarget || (isSelected && isPaneActive) {
            textColor = ChromeContrast.readableTextColor(
                preferred: colors.textPrimary,
                fallback: colors.textSecondary,
                on: backgroundColor
            )
        } else if isSelected {
            textColor = ChromeContrast.readableTextColor(
                preferred: colors.textSecondary,
                fallback: colors.textPrimary,
                on: backgroundColor
            )
        } else {
            textColor = ChromeContrast.readableTextColor(
                preferred: colors.textSecondary,
                fallback: colors.textPrimary,
                on: backgroundColor
            )
        }
        titleLabel.textColor = textColor
        iconView.contentTintColor = textColor
        closeButton.contentTintColor = textColor

        titleLabel.alphaValue = 1.0
        iconView.alphaValue = 1.0
        closeButton.alphaValue = 1.0

        // On hover: swap icon for close button
        iconView.isHidden = isHovered
        closeButton.isHidden = !isHovered

        needsDisplay = true
    }

    private func currentBackgroundColor() -> NSColor {
        if isDropTarget {
            return ChromeContrast.blend(colors.accent, alpha: isPaneActive ? 0.18 : 0.12, over: tabBarBackgroundColor())
        }
        if isSelected {
            if isPaneActive {
                return colors.background
            }
            return colors.surface.blended(withFraction: 0.35, of: colors.background) ?? colors.surface
        }
        if isHovered {
            return ChromeContrast.blend(colors.textPrimary, alpha: isPaneActive ? 0.055 : 0.035, over: tabBarBackgroundColor())
        }
        return tabBarBackgroundColor()
    }

    private func tabBarBackgroundColor() -> NSColor {
        isPaneActive ? colors.surface : (colors.surface.blended(withFraction: 0.50, of: colors.background) ?? colors.surface)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        if isDropTarget {
            colors.accent.withAlphaComponent(isPaneActive ? 0.18 : 0.12).setFill()
            b.fill()
        } else if isSelected {
            let fillColor: NSColor
            if isPaneActive {
                fillColor = colors.background
            } else {
                fillColor = colors.surface.blended(withFraction: 0.35, of: colors.background) ?? colors.surface
            }
            fillColor.setFill()
            b.fill()

            // Accent indicator at bottom edge
            colors.accent.withAlphaComponent(isPaneActive ? 1.0 : 0.45).setFill()
            NSRect(x: 0, y: 0, width: b.width, height: 2).fill()
        } else if isHovered {
            colors.textPrimary.withAlphaComponent(isPaneActive ? 0.055 : 0.035).setFill()
            b.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    // Prevent close button from capturing mouse events — we handle
    // all clicks in mouseDown so drag-to-reorder works correctly
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let closeHitArea = closeButton.frame.insetBy(dx: -4, dy: -4)
        if isHovered && closeHitArea.contains(point) {
            closeAction?()
            return
        }
        mouseDownLocation = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation else { return }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let distance = hypot(currentLocation.x - startLocation.x, currentLocation.y - startLocation.y)

        if distance > 5 {
            mouseDownLocation = nil
            dragAction?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownLocation != nil {
            tabAction?()
        }
        mouseDownLocation = nil
    }

    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            layer?.render(in: context)
        }
        image.unlockFocus()
        return image
    }
}
