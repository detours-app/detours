import AppKit

final class FileListCell: NSTableCellView, RowSelectionStyling {
    private let gitMark = GitMarkView()
    private let iconView = NSImageView()
    private let cloudIcon = NSImageView()
    private let linkIcon = NSImageView()
    private let lockIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sharedLabel = NSTextField(labelWithString: "")
    private var itemLocation: Location?
    private var isDropTarget: Bool = false
    private var isHiddenFile: Bool = false
    private var isReadable: Bool = true
    private var gitStatus: GitStatus?
    private var iconLeadingConstraint: NSLayoutConstraint?
    private var gitMarkGapConstraint: NSLayoutConstraint?
    private var gitMarkWidthConstraint: NSLayoutConstraint?
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
    private var lockLeadingConstraint: NSLayoutConstraint?
    private var lockBottomConstraint: NSLayoutConstraint?
    private var lockWidthConstraint: NSLayoutConstraint?
    private var lockHeightConstraint: NSLayoutConstraint?
    private var nameLabelLeadingConstraint: NSLayoutConstraint?
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

        addSubview(gitMark)

        // Layout
        gitMark.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cloudIcon.translatesAutoresizingMaskIntoConstraints = false
        linkIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        sharedLabel.translatesAutoresizingMaskIntoConstraints = false

        // Create dynamic constraints for density and folder expansion changes.
        let density = SettingsManager.shared.fileListRowDensity
        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: density.standardIconLeading)
        gitMarkGapConstraint = gitMark.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 0)
        gitMarkWidthConstraint = gitMark.widthAnchor.constraint(equalToConstant: 0)
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
        lockLeadingConstraint = lockIcon.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -density.overlayOffset)
        lockBottomConstraint = lockIcon.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: density.overlayOffset)
        lockWidthConstraint = lockIcon.widthAnchor.constraint(equalToConstant: density.secondaryAccessoryIconSize)
        lockHeightConstraint = lockIcon.heightAnchor.constraint(equalToConstant: density.secondaryAccessoryIconSize)
        nameLabelLeadingConstraint = nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: density.nameIconGap)
        nameLabelCenterYConstraint = nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: density.verticalTextOffset)
        sharedLabelCenterYConstraint = sharedLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: density.verticalTextOffset)

        NSLayoutConstraint.activate([
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

            lockLeadingConstraint!,
            lockBottomConstraint!,
            lockWidthConstraint!,
            lockHeightConstraint!,

            // Name follows the icon at a density-controlled gap.
            nameLabelLeadingConstraint!,
            nameLabelCenterYConstraint!,

            // Git mark follows the name; it collapses to nothing for clean files.
            gitMarkGapConstraint!,
            gitMarkWidthConstraint!,
            gitMark.heightAnchor.constraint(equalToConstant: GitMarkView.markSize),
            gitMark.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            // Shared label: after name and mark, before trailing edge
            sharedLabel.leadingAnchor.constraint(equalTo: gitMark.trailingAnchor, constant: 8),
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
        updateColorsForBackgroundStyle()
    }

    func configure(with item: FileItem, isDropTarget: Bool = false) {
        itemLocation = item.location
        self.isDropTarget = isDropTarget
        self.isHiddenFile = item.isHiddenFile
        self.isReadable = item.isReadable
        self.gitStatus = item.gitStatus
        baseIcon = item.icon
        isFolderIcon = item.isNavigableFolder
        updateIcon()
        itemName = item.name
        nameLabel.stringValue = item.name
        linkIcon.isHidden = !item.isSymbolicLink
        lockIcon.isHidden = item.isReadable

        applyDensityMetrics()
        let density = SettingsManager.shared.fileListRowDensity

        // Adjust leading padding based on folder expansion and item type
        let folderExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        if folderExpansionEnabled {
            iconLeadingConstraint?.constant = item.isNavigableFolder ? density.expandedFolderIconLeading : density.expandedFileIconLeading
        } else {
            iconLeadingConstraint?.constant = density.standardIconLeading
        }

        // Update theme colors in case they changed
        updateThemeColors()
        // Update selection colors based on current background style
        updateColorsForBackgroundStyle()

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
        lockLeadingConstraint?.constant = -density.overlayOffset
        lockBottomConstraint?.constant = density.overlayOffset
        lockWidthConstraint?.constant = density.secondaryAccessoryIconSize
        lockHeightConstraint?.constant = density.secondaryAccessoryIconSize
        nameLabelLeadingConstraint?.constant = density.nameIconGap
        nameLabelCenterYConstraint?.constant = density.verticalTextOffset
        sharedLabelCenterYConstraint?.constant = density.verticalTextOffset
    }

    private func updateGitMark() {
        let status = gitStatus ?? .clean
        gitMark.status = status
        let isVisible = status != .clean
        gitMarkGapConstraint?.constant = isVisible ? 5 : 0
        gitMarkWidthConstraint?.constant = isVisible ? GitMarkView.markSize : 0
        gitMark.color = Self.gitMarkColor(for: status, theme: ThemeManager.shared.currentTheme, selection: rowSelectionState)
    }

    /// Git mark colour for the row's state: white or the selection text on an active
    /// selection, otherwise the git token held to 3:1 against the surface it sits on.
    static func gitMarkColor(for status: GitStatus, theme: Theme, selection: RowSelectionState) -> NSColor {
        switch selection {
        case .active:
            return theme.selectionText
        case .inactive:
            return ChromeContrast.stateIndicatorColor(preferred: status.color(in: theme), fallback: theme.textPrimary, on: theme.inactiveSelection)
        case .none:
            return ChromeContrast.stateIndicatorColor(preferred: status.color(in: theme), fallback: theme.textPrimary, on: theme.content)
        }
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
        guard let itemLocation else { return }
        let isCut = ClipboardManager.shared.isItemCut(itemLocation)
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
        var label = itemName
        if let gitLabel = gitStatus?.markLabel {
            label += ", \(gitLabel)"
        }
        if isCut {
            label += ", pending move"
        }
        setAccessibilityLabel(label)
        setAccessibilityHelp(isCut ? "This item will move when you paste it." : nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleCutItemsChanged() {
        updateCutAppearance()
    }

    private var baseIcon: NSImage?
    private var isFolderIcon = false

    /// Folders take the accent; on an active selection a lighter accent keeps them visible on the row.
    private func updateIcon() {
        guard let baseIcon else { return }
        iconView.image = isFolderIcon
            ? FileItem.tintedFolderIcon(baseIcon, onSelection: rowSelectionState == .active)
            : baseIcon
    }

    var rowSelectionState: RowSelectionState = .none {
        didSet {
            if rowSelectionState != oldValue {
                updateColorsForBackgroundStyle()
                updateIcon()
            }
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
        if rowSelectionState != .none {
            let isActive = rowSelectionState == .active
            let selectedForeground = ChromeContrast.fileListSelectedForeground(for: theme, active: isActive)
            let selectedSecondaryForeground = ChromeContrast.fileListSelectedSecondaryForeground(for: theme, active: isActive)
            nameLabel.textColor = selectedForeground
            sharedLabel.textColor = selectedSecondaryForeground
            cloudIcon.contentTintColor = selectedSecondaryForeground
            linkIcon.contentTintColor = selectedSecondaryForeground
            lockIcon.contentTintColor = selectedSecondaryForeground
        } else {
            // Normal row: use theme colors
            nameLabel.textColor = theme.textPrimary
            sharedLabel.textColor = theme.textSecondary
            cloudIcon.contentTintColor = theme.textSecondary
            linkIcon.contentTintColor = theme.textSecondary
            lockIcon.contentTintColor = theme.textSecondary
        }
        updateGitMark()
    }
}
