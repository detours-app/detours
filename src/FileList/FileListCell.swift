import AppKit

final class FileListCell: NSTableCellView {
    private let gitStatusBar = NSView()
    private let iconView = NSImageView()
    private let cloudIcon = NSImageView()
    private let linkIcon = NSImageView()
    private let lockIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sharedLabel = NSTextField(labelWithString: "")
    private var itemURL: URL?
    private var isDropTarget: Bool = false
    private var isHiddenFile: Bool = false
    private var isNavigableFolder: Bool = false
    private var isReadable: Bool = true
    private var originalIcon: NSImage?
    private var gitStatus: GitStatus?
    private var iconLeadingConstraint: NSLayoutConstraint?
    private var gitBarLeadingConstraint: NSLayoutConstraint?
    private var gitBarHeightConstraint: NSLayoutConstraint?
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var cloudTrailingConstraint: NSLayoutConstraint?
    private var cloudBottomConstraint: NSLayoutConstraint?
    private var cloudWidthConstraint: NSLayoutConstraint?
    private var cloudHeightConstraint: NSLayoutConstraint?
    private var linkTrailingConstraint: NSLayoutConstraint?
    private var linkTopConstraint: NSLayoutConstraint?
    private var linkWidthConstraint: NSLayoutConstraint?
    private var linkHeightConstraint: NSLayoutConstraint?
    private var lockTrailingConstraint: NSLayoutConstraint?
    private var lockBottomConstraint: NSLayoutConstraint?
    private var lockWidthConstraint: NSLayoutConstraint?
    private var lockHeightConstraint: NSLayoutConstraint?
    private var nameLabelCenterYConstraint: NSLayoutConstraint?
    private var sharedLabelCenterYConstraint: NSLayoutConstraint?
    private var itemName: String = ""

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

        linkIcon.imageScaling = .scaleProportionallyUpOrDown
        linkIcon.contentTintColor = .secondaryLabelColor
        linkIcon.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: "Symbolic link")
        linkIcon.isHidden = true
        addSubview(linkIcon)

        lockIcon.imageScaling = .scaleProportionallyUpOrDown
        lockIcon.contentTintColor = .secondaryLabelColor
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Permission denied")
        lockIcon.isHidden = true
        addSubview(lockIcon)

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
        linkIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        sharedLabel.translatesAutoresizingMaskIntoConstraints = false

        // Create dynamic constraints for density and folder expansion changes.
        let density = SettingsManager.shared.fileListRowDensity
        gitBarLeadingConstraint = gitStatusBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5)
        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        gitBarHeightConstraint = gitStatusBar.heightAnchor.constraint(equalToConstant: density.gitMarkerHeight)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: density.primaryIconSize)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: density.primaryIconSize)
        cloudTrailingConstraint = cloudIcon.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: density.overlayOffset)
        cloudBottomConstraint = cloudIcon.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: density.overlayOffset)
        cloudWidthConstraint = cloudIcon.widthAnchor.constraint(equalToConstant: density.accessoryIconSize)
        cloudHeightConstraint = cloudIcon.heightAnchor.constraint(equalToConstant: density.accessoryIconSize)
        linkTrailingConstraint = linkIcon.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: density.overlayOffset)
        linkTopConstraint = linkIcon.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -density.overlayOffset)
        linkWidthConstraint = linkIcon.widthAnchor.constraint(equalToConstant: density.secondaryAccessoryIconSize)
        linkHeightConstraint = linkIcon.heightAnchor.constraint(equalToConstant: density.secondaryAccessoryIconSize)
        lockTrailingConstraint = lockIcon.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: density.overlayOffset)
        lockBottomConstraint = lockIcon.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: density.overlayOffset)
        lockWidthConstraint = lockIcon.widthAnchor.constraint(equalToConstant: density.secondaryAccessoryIconSize)
        lockHeightConstraint = lockIcon.heightAnchor.constraint(equalToConstant: density.secondaryAccessoryIconSize)
        nameLabelCenterYConstraint = nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: density.verticalTextOffset)
        sharedLabelCenterYConstraint = sharedLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: density.verticalTextOffset)

        NSLayoutConstraint.activate([
            // Git status bar: fixed width, density-controlled height.
            gitBarLeadingConstraint!,
            gitStatusBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitStatusBar.widthAnchor.constraint(equalToConstant: 2),
            gitBarHeightConstraint!,

            // Icon: density-controlled size, centered vertically.
            iconLeadingConstraint!,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint!,
            iconHeightConstraint!,

            // Overlay icons stay pinned to the main icon with density-controlled sizes.
            cloudTrailingConstraint!,
            cloudBottomConstraint!,
            cloudWidthConstraint!,
            cloudHeightConstraint!,

            linkTrailingConstraint!,
            linkTopConstraint!,
            linkWidthConstraint!,
            linkHeightConstraint!,

            lockTrailingConstraint!,
            lockBottomConstraint!,
            lockWidthConstraint!,
            lockHeightConstraint!,

            // Name: 8px after icon
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabelCenterYConstraint!,

            // Shared label: after name, before trailing edge
            sharedLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            sharedLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            sharedLabelCenterYConstraint!,
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
        linkIcon.contentTintColor = theme.textSecondary
        lockIcon.contentTintColor = theme.textSecondary
    }

    @objc private func handleThemeChange() {
        updateThemeColors()
    }

    func configure(with item: FileItem, isDropTarget: Bool = false) {
        if case .local(let url) = item.location {
            itemURL = url
        } else {
            itemURL = nil
        }
        self.isDropTarget = isDropTarget
        self.isHiddenFile = item.isHiddenFile
        self.isNavigableFolder = item.isNavigableFolder
        self.isReadable = item.isReadable
        self.gitStatus = item.gitStatus
        originalIcon = item.icon
        iconView.image = item.icon
        itemName = item.name
        nameLabel.stringValue = item.name
        linkIcon.isHidden = !item.isSymbolicLink
        lockIcon.isHidden = item.isReadable

        applyDensityMetrics()

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

        if let sharedLabelText = item.sharedLabelText {
            sharedLabel.stringValue = sharedLabelText
            sharedLabel.isHidden = false
        } else {
            sharedLabel.stringValue = ""
            sharedLabel.isHidden = true
        }

        updateCutAppearance()
        updateDropTargetAppearance()
    }

    private func applyDensityMetrics() {
        let density = SettingsManager.shared.fileListRowDensity
        gitBarHeightConstraint?.constant = density.gitMarkerHeight
        iconWidthConstraint?.constant = density.primaryIconSize
        iconHeightConstraint?.constant = density.primaryIconSize
        cloudTrailingConstraint?.constant = density.overlayOffset
        cloudBottomConstraint?.constant = density.overlayOffset
        cloudWidthConstraint?.constant = density.accessoryIconSize
        cloudHeightConstraint?.constant = density.accessoryIconSize
        linkTrailingConstraint?.constant = density.overlayOffset
        linkTopConstraint?.constant = -density.overlayOffset
        linkWidthConstraint?.constant = density.secondaryAccessoryIconSize
        linkHeightConstraint?.constant = density.secondaryAccessoryIconSize
        lockTrailingConstraint?.constant = density.overlayOffset
        lockBottomConstraint?.constant = density.overlayOffset
        lockWidthConstraint?.constant = density.secondaryAccessoryIconSize
        lockHeightConstraint?.constant = density.secondaryAccessoryIconSize
        nameLabelCenterYConstraint?.constant = density.verticalTextOffset
        sharedLabelCenterYConstraint?.constant = density.verticalTextOffset
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
        } else if !isReadable {
            alpha = 0.55
        } else if isHiddenFile {
            alpha = 0.6
        } else {
            alpha = 1.0
        }
        iconView.alphaValue = alpha
        cloudIcon.alphaValue = alpha
        linkIcon.alphaValue = alpha
        lockIcon.alphaValue = alpha
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

    override func layout() {
        super.layout()
        updateTooltipIfTruncated()
    }

    private func updateTooltipIfTruncated() {
        guard !itemName.isEmpty else {
            nameLabel.toolTip = nil
            return
        }

        // Measure the text width
        let textWidth = (itemName as NSString).size(withAttributes: [.font: nameLabel.font!]).width

        // Compare to available width (nameLabel's frame width)
        if textWidth > nameLabel.frame.width {
            nameLabel.toolTip = itemName
        } else {
            nameLabel.toolTip = nil
        }
    }

    private func updateColorsForBackgroundStyle() {
        let theme = ThemeManager.shared.currentTheme
        let isEmphasized = backgroundStyle == .emphasized

        if isEmphasized {
            // Selected row: white text on accent background
            nameLabel.textColor = .white
            sharedLabel.textColor = NSColor.white.withAlphaComponent(0.8)
            cloudIcon.contentTintColor = .white
            linkIcon.contentTintColor = .white
            lockIcon.contentTintColor = .white
            // Tint folder icons with accent color
            if isNavigableFolder, let original = originalIcon {
                iconView.image = Self.tintedIcon(original, color: theme.accent)
            }
        } else {
            // Normal row: use theme colors
            nameLabel.textColor = theme.textPrimary
            sharedLabel.textColor = theme.textSecondary
            cloudIcon.contentTintColor = theme.textSecondary
            linkIcon.contentTintColor = theme.textSecondary
            lockIcon.contentTintColor = theme.textSecondary
            // Restore original icon
            iconView.image = originalIcon
        }
    }

    /// Creates a tinted version of an icon using the given color
    private static func tintedIcon(_ icon: NSImage, color: NSColor) -> NSImage {
        let size = icon.size
        guard size.width > 0, size.height > 0 else { return icon }

        let tinted = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw original icon
            icon.draw(in: rect)

            // Overlay tint color
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(color.withAlphaComponent(0.8).cgColor)
            ctx.fill(rect)

            return true
        }
        return tinted
    }
}
