import AppKit

final class FileListCell: NSTableCellView {
    private let iconView = NSImageView()
    private let cloudIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sharedLabel = NSTextField(labelWithString: "")
    private var itemURL: URL?
    private var isDropTarget: Bool = false
    private var isHiddenFile: Bool = false

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
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cloudIcon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        sharedLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Icon: 16x16, centered vertically, 4px from leading edge
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            // Cloud icon: 12x12, bottom-right of main icon
            cloudIcon.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            cloudIcon.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            cloudIcon.widthAnchor.constraint(equalToConstant: 12),
            cloudIcon.heightAnchor.constraint(equalToConstant: 12),

            // Name: 8px after icon
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
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
        iconView.image = item.icon
        nameLabel.stringValue = item.name

        // Update theme colors in case they changed
        updateThemeColors()

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

    private func updateDropTargetAppearance() {
        if isDropTarget {
            wantsLayer = true
            layer?.borderColor = ThemeManager.shared.currentTheme.accent.cgColor
            layer?.borderWidth = 2
            layer?.cornerRadius = 4
        } else {
            layer?.borderWidth = 0
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
}
