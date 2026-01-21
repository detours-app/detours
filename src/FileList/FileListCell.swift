import AppKit

final class FileListCell: NSTableCellView {
    private let gitStatusBar = NSView()
    private let iconView = NSImageView()
    private let cloudIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sharedLabel = NSTextField(labelWithString: "")
    private var itemURL: URL?
    private var isDropTarget: Bool = false
    private var isHiddenFile: Bool = false
    private var isNavigableFolder: Bool = false
    private var originalIcon: NSImage?
    private var gitStatus: GitStatus?
    private var iconLeadingConstraint: NSLayoutConstraint?
    private var gitBarLeadingConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        // Git status bar - 2px wide, 14px tall, in 8px gutter
        gitStatusBar.wantsLayer = true
        gitStatusBar.layer?.cornerRadius = 1
        gitStatusBar.isHidden = true
        addSubview(gitStatusBar)

        // Icon setup - 16x16
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        self.imageView = iconView

        // Cloud icon for iCloud status - 12x12
        cloudIcon.imageScaling = .scaleProportionallyUpOrDown
        cloudIcon.contentTintColor = .secondaryLabelColor
        cloudIcon.isHidden = true
        addSubview(cloudIcon)

        // Name label setup
        updateThemeColors()
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)
        self.textField = nameLabel

        // Shared label setup - smaller, secondary color
        sharedLabel.lineBreakMode = .byTruncatingTail
        sharedLabel.isEditable = false
        sharedLabel.isBordered = false
        sharedLabel.drawsBackground = false
        sharedLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(sharedLabel)

        // Layout
        gitStatusBar.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cloudIcon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        sharedLabel.translatesAutoresizingMaskIntoConstraints = false

        // Create dynamic constraints for git bar and icon leading (adjusted when folder expansion is enabled)
        gitBarLeadingConstraint = gitStatusBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5)
        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)

        NSLayoutConstraint.activate([
            // Git status bar: 2px × 14px, centered vertically (leading is dynamic)
            gitBarLeadingConstraint!,
            gitStatusBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitStatusBar.widthAnchor.constraint(equalToConstant: 2),
            gitStatusBar.heightAnchor.constraint(equalToConstant: 14),

            // Icon: 16x16, centered vertically (leading is dynamic)
            iconLeadingConstraint!,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            // Cloud icon: 12x12, bottom-right of main icon
            cloudIcon.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            cloudIcon.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            cloudIcon.widthAnchor.constraint(equalToConstant: 12),
            cloudIcon.heightAnchor.constraint(equalToConstant: 12),

            // Name: 6px after icon (tighter spacing)
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Shared label: after name, before trailing edge
            sharedLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            sharedLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            sharedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCutItemsChanged),
            name: ClipboardManager.cutItemsDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )
    }

    private func updateThemeColors() {
        let theme = ThemeManager.shared.currentTheme
        let fontSize = ThemeManager.shared.fontSize
        nameLabel.font = theme.font(size: fontSize)
        nameLabel.textColor = theme.textPrimary
        sharedLabel.font = theme.font(size: fontSize - 2)
        sharedLabel.textColor = theme.textSecondary
        cloudIcon.contentTintColor = theme.textSecondary
    }

    @objc private func handleThemeChange() {
        updateThemeColors()
    }

    func configure(with item: FileItem, isDropTarget: Bool = false) {
        itemURL = item.url
        self.isDropTarget = isDropTarget
        self.isHiddenFile = item.isHiddenFile
        self.isNavigableFolder = item.isNavigableFolder
        self.gitStatus = item.gitStatus
        originalIcon = item.icon
        iconView.image = item.icon
        nameLabel.stringValue = item.name

        // Adjust leading padding based on folder expansion and item type
        // Folders never have git status, so they can use tighter spacing
        let folderExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        if folderExpansionEnabled {
            // Folders: minimal spacing (no git bar needed)
            // Files: slightly more space to accommodate git bar
            iconLeadingConstraint?.constant = item.isNavigableFolder ? 2 : 4
            gitBarLeadingConstraint?.constant = 1
        } else {
            // Standard spacing with room for git status bar
            iconLeadingConstraint?.constant = 12
            gitBarLeadingConstraint?.constant = 5
        }

        // Update theme colors in case they changed
        updateThemeColors()
        // Update selection colors based on current background style
        updateColorsForBackgroundStyle()

        // Git status indicator
        updateGitStatusBar()

        // iCloud status indicator
        switch item.iCloudStatus {
        case .notDownloaded:
            cloudIcon.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "Not downloaded")
            cloudIcon.isHidden = false
        case .downloading:
            cloudIcon.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloading")
            cloudIcon.isHidden = false
        case .downloaded, .local:
            cloudIcon.isHidden = true
        }

        if let sharedBy = item.sharedByName {
            sharedLabel.stringValue = "Shared by \(sharedBy)"
            sharedLabel.isHidden = false
        } else {
            sharedLabel.stringValue = ""
            sharedLabel.isHidden = true
        }

        updateCutAppearance()
        updateDropTargetAppearance()
    }

    private func updateGitStatusBar() {
        guard let status = gitStatus, status != .clean else {
            gitStatusBar.isHidden = true
            return
        }

        gitStatusBar.isHidden = false
        gitStatusBar.layer?.backgroundColor = status.color(for: effectiveAppearance).cgColor
    }

    private func updateDropTargetAppearance() {
        if isDropTarget {
            wantsLayer = true
            layer?.borderColor = ThemeManager.shared.currentTheme.accent.cgColor
            layer?.borderWidth = 2
            layer?.cornerRadius = 4
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
            layer?.cornerRadius = 0
        }
    }

    private func updateCutAppearance() {
        guard let url = itemURL else { return }
        let isCut = ClipboardManager.shared.isItemCut(url)
        // Cut items at 0.5, hidden files at 0.6, normal at 1.0
        let alpha: CGFloat
        if isCut {
            alpha = 0.5
        } else if isHiddenFile {
            alpha = 0.6
        } else {
            alpha = 1.0
        }
        iconView.alphaValue = alpha
        cloudIcon.alphaValue = alpha
        nameLabel.alphaValue = alpha
        sharedLabel.alphaValue = alpha
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleCutItemsChanged() {
        updateCutAppearance()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColorsForBackgroundStyle()
        }
    }

    private func updateColorsForBackgroundStyle() {
        let theme = ThemeManager.shared.currentTheme
        let isEmphasized = backgroundStyle == .emphasized

        if isEmphasized {
            // Selected row: use accentText (white) for text visibility
            nameLabel.textColor = theme.accentText
            sharedLabel.textColor = theme.accentText
            cloudIcon.contentTintColor = theme.accentText
            // Only lighten folder icons (which are tinted), not file/app icons
            if isNavigableFolder, let original = originalIcon {
                iconView.image = Self.lightenedIcon(original, amount: 0.7)
            }
        } else {
            // Normal row: use theme colors
            nameLabel.textColor = theme.textPrimary
            sharedLabel.textColor = theme.textSecondary
            cloudIcon.contentTintColor = theme.textSecondary
            // Restore original icon
            iconView.image = originalIcon
        }
    }

    /// Creates a lightened version of an icon by blending with white
    private static func lightenedIcon(_ icon: NSImage, amount: CGFloat) -> NSImage {
        let size = icon.size
        guard size.width > 0, size.height > 0 else { return icon }

        let lightened = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw original icon
            icon.draw(in: rect)

            // Overlay white with partial opacity to lighten
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(NSColor.white.withAlphaComponent(amount).cgColor)
            ctx.fill(rect)

            return true
        }
        return lightened
    }
}
