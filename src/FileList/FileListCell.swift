import AppKit

final class FileListCell: NSTableCellView {
    private let iconView = NSImageView()
    private let cloudIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sharedLabel = NSTextField(labelWithString: "")
    private var itemURL: URL?

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

        // Name label setup - SF Mono 13px
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)
        self.textField = nameLabel

        // Shared label setup - smaller, secondary color
        sharedLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sharedLabel.textColor = .secondaryLabelColor
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
    }

    func configure(with item: FileItem) {
        itemURL = item.url
        iconView.image = item.icon
        nameLabel.stringValue = item.name

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
    }

    private func updateCutAppearance() {
        guard let url = itemURL else { return }
        let isCut = ClipboardManager.shared.isItemCut(url)
        let alpha: CGFloat = isCut ? 0.5 : 1.0
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
