import AppKit

final class SidebarItemView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let capacityLabel = NSTextField(labelWithString: "")
    private let protocolBadge = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()
    private var capacityTrailingConstraint: NSLayoutConstraint?
    private var protocolBadgeTrailingConstraint: NSLayoutConstraint?

    var onEject: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        capacityLabel.translatesAutoresizingMaskIntoConstraints = false
        capacityLabel.font = .systemFont(ofSize: 10)
        capacityLabel.alignment = .right
        capacityLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        protocolBadge.translatesAutoresizingMaskIntoConstraints = false
        protocolBadge.font = .systemFont(ofSize: 9, weight: .medium)
        protocolBadge.alignment = .right
        protocolBadge.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        protocolBadge.isHidden = true

        // Eject button setup
        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.bezelStyle = .inline
        ejectButton.isBordered = false
        let ejectImage = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        let smallConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .light)
        ejectButton.image = ejectImage?.withSymbolConfiguration(smallConfig)
        ejectButton.imageScaling = .scaleProportionallyDown
        ejectButton.imagePosition = .imageOnly
        ejectButton.target = self
        ejectButton.action = #selector(ejectClicked)
        ejectButton.isHidden = true

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(capacityLabel)
        addSubview(protocolBadge)
        addSubview(ejectButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: capacityLabel.leadingAnchor, constant: -4),

            capacityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            capacityLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 50),

            protocolBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            protocolBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 10),
            ejectButton.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    func configure(with item: SidebarItem, theme: Theme) {
        switch item {
        case .section(let section):
            configureAsSection(section, theme: theme)
        case .device(let volume):
            configureAsDevice(volume, theme: theme)
        case .server(let server):
            configureAsServer(server, theme: theme)
        case .favorite(let url):
            configureAsFavorite(url, theme: theme)
        }
    }

    private func configureAsSection(_ section: SidebarSection, theme: Theme) {
        iconView.isHidden = true
        nameLabel.stringValue = section.title
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = theme.textSecondary
        capacityLabel.isHidden = true

        // Adjust leading constraint for section headers (no icon)
        if let constraint = constraints.first(where: { $0.firstAnchor == nameLabel.leadingAnchor }) {
            constraint.isActive = false
        }
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).isActive = true
    }

    private func configureAsDevice(_ volume: VolumeInfo, theme: Theme) {
        iconView.isHidden = false
        iconView.image = volume.icon
        nameLabel.stringValue = volume.name
        nameLabel.font = theme.font(size: 12)
        nameLabel.textColor = theme.textPrimary

        // Show eject button for ejectable volumes
        ejectButton.isHidden = !volume.isEjectable
        ejectButton.contentTintColor = theme.textSecondary
        ejectButton.alphaValue = 0.7

        // Update capacity trailing constraint based on eject button visibility
        capacityTrailingConstraint?.isActive = false
        if volume.isEjectable {
            capacityTrailingConstraint = capacityLabel.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -4)
        } else {
            capacityTrailingConstraint = capacityLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        }
        capacityTrailingConstraint?.isActive = true

        if let capacity = volume.capacityString {
            capacityLabel.isHidden = false
            capacityLabel.stringValue = capacity
            capacityLabel.font = theme.font(size: 10)
            capacityLabel.textColor = theme.textTertiary
        } else {
            capacityLabel.isHidden = true
        }

        resetNameLeading()
    }

    @objc private func ejectClicked() {
        onEject?()
    }

    private func configureAsServer(_ server: NetworkServer, theme: Theme) {
        iconView.isHidden = false
        let serverIcon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Server")
        iconView.image = serverIcon
        iconView.contentTintColor = theme.textSecondary
        nameLabel.stringValue = server.name
        nameLabel.font = theme.font(size: 12)
        nameLabel.textColor = theme.textPrimary
        capacityLabel.isHidden = true

        // Show protocol badge
        protocolBadge.isHidden = false
        protocolBadge.stringValue = server.protocol.displayName
        protocolBadge.font = .systemFont(ofSize: 9, weight: .medium)
        protocolBadge.textColor = theme.textTertiary

        resetNameLeading()
    }

    func configureAsPlaceholder(_ placeholder: NetworkPlaceholder, theme: Theme) {
        iconView.isHidden = true
        nameLabel.stringValue = placeholder.text
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = theme.textTertiary
        capacityLabel.isHidden = true
        protocolBadge.isHidden = true

        // Adjust leading constraint for placeholder (no icon, indented)
        for constraint in constraints where constraint.firstAnchor == nameLabel.leadingAnchor {
            constraint.isActive = false
        }
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).isActive = true
    }

    private func configureAsFavorite(_ url: URL, theme: Theme) {
        iconView.isHidden = false
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        nameLabel.font = theme.font(size: 12)
        capacityLabel.isHidden = true

        // Check if favorite exists
        if FileManager.default.fileExists(atPath: url.path) {
            nameLabel.stringValue = url.lastPathComponent
            nameLabel.textColor = theme.textPrimary
        } else {
            nameLabel.stringValue = url.lastPathComponent
            nameLabel.textColor = theme.textTertiary
        }

        resetNameLeading()
    }

    private func resetNameLeading() {
        // Reset leading constraint to be after icon
        for constraint in constraints where constraint.firstAnchor == nameLabel.leadingAnchor {
            constraint.isActive = false
        }
        nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6).isActive = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.image = nil
        iconView.isHidden = false
        iconView.contentTintColor = nil
        nameLabel.stringValue = ""
        capacityLabel.stringValue = ""
        capacityLabel.isHidden = true
        protocolBadge.stringValue = ""
        protocolBadge.isHidden = true
        capacityTrailingConstraint?.isActive = false
        capacityTrailingConstraint = nil
        ejectButton.isHidden = true
        ejectButton.alphaValue = 1.0
        onEject = nil
    }
}
