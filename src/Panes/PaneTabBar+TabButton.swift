import AppKit
import os.log

// MARK: - Tab Button

final class TabButton: NSView {
    private let iconView = NSImageView()
    private let closeButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isSelected: Bool = false
    private var isHovered: Bool = false
    private var isDropTarget: Bool = false
    private var isPaneActive: Bool = true
    private var trackingArea: NSTrackingArea?
    private let colors: Theme

    static let pillHeight: CGFloat = 26
    static let pillRadius: CGFloat = 7
    static let minimumWidth: CGFloat = 96
    static let maximumWidth: CGFloat = 220
    static let fontSize: CGFloat = 12
    static let underlineHeight: CGFloat = 2
    /// Space below the pill, so the pill sits 8 pt under the bar's top edge in a 40 pt bar
    static let pillBottomInset: CGFloat = 6
    private static let iconSize: CGFloat = 14
    private static let leadingPad: CGFloat = 10
    private static let iconTextGap: CGFloat = 6
    private static let trailingPad: CGFloat = 10

    var tabAction: (() -> Void)?
    var closeAction: (() -> Void)?
    var dragAction: ((NSEvent) -> Void)?

    private var mouseDownLocation: NSPoint?

    /// Width from the title, clamped so short titles keep a usable target and long ones truncate in the middle
    var idealWidth: CGFloat {
        let textWidth = ceil(titleLabel.intrinsicContentSize.width)
        let natural = Self.leadingPad + Self.iconSize + Self.iconTextGap + textWidth + Self.trailingPad
        return min(Self.maximumWidth, max(Self.minimumWidth, natural))
    }

    private var pillRect: NSRect {
        NSRect(x: 0, y: Self.pillBottomInset, width: bounds.width, height: Self.pillHeight)
    }

    init(title: String, symbolName: String, isSelected: Bool, theme: Theme) {
        self.isSelected = isSelected
        self.colors = theme
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
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = colors.textSecondary
        iconView.imageScaling = .scaleNone

        addSubview(iconView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPad),
            iconView.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -(Self.pillBottomInset + Self.pillHeight / 2)),
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
            closeButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Self.iconSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    private func setupTitleLabel(_ title: String) {
        titleLabel.stringValue = title
        titleLabel.font = colors.uiFont(size: Self.fontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(titleLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconTextGap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingPad),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])
    }

    @objc private func closeClicked() {
        closeAction?()
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
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
        let textColor: NSColor
        if isDropTarget || (isSelected && isPaneActive) {
            textColor = ChromeContrast.readableTextColor(preferred: colors.textPrimary, fallback: colors.textPrimary, on: currentBackgroundColor())
        } else {
            textColor = ChromeContrast.readableTextColor(preferred: colors.textSecondary, fallback: colors.textPrimary, on: currentBackgroundColor())
        }
        titleLabel.textColor = textColor
        iconView.contentTintColor = textColor
        closeButton.contentTintColor = textColor

        // On hover: swap icon for close button
        iconView.isHidden = isHovered
        closeButton.isHidden = !isHovered

        needsDisplay = true
    }

    private func currentBackgroundColor() -> NSColor {
        if isDropTarget {
            return ChromeContrast.flatten(colors.dropTarget, over: colors.header)
        }
        if isSelected {
            return colors.raised
        }
        if isHovered {
            return ChromeContrast.flatten(colors.hover, over: colors.header)
        }
        return colors.header
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: Self.pillRadius, yRadius: Self.pillRadius)

        if isDropTarget {
            colors.dropTarget.setFill()
            pill.fill()
        } else if isSelected {
            // The current tab is a raised pill: a hairline ring and a soft drop below it.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(colors.isDark ? 0.4 : 0.08)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2
            shadow.set()
            colors.raised.setFill()
            pill.fill()
            NSGraphicsContext.restoreGraphicsState()

            colors.hairline.setStroke()
            let ring = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.25, dy: 0.25), xRadius: Self.pillRadius, yRadius: Self.pillRadius)
            ring.lineWidth = 0.5
            ring.stroke()

            // The active pane's current tab carries the accent underline.
            if isPaneActive {
                ChromeContrast.stateIndicatorColor(preferred: colors.accent, fallback: colors.textPrimary, on: colors.header).setFill()
                let inset = Self.pillRadius
                NSRect(x: inset, y: 0, width: bounds.width - inset * 2, height: Self.underlineHeight).fill()
            }
        } else if isHovered {
            colors.hover.setFill()
            pill.fill()
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
