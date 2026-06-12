import AppKit

final class SidebarItemView: NSTableCellView {
    private let iconView = NSImageView()
    private let statusDot = NSView()
    private let statusSpinner = NSProgressIndicator()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
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

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.isHidden = true

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .mini
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.isHidden = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isHidden = true

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
        let smallConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        ejectButton.image = ejectImage?.withSymbolConfiguration(smallConfig)
        ejectButton.imageScaling = .scaleProportionallyDown
        ejectButton.imagePosition = .imageOnly
        ejectButton.target = self
        ejectButton.action = #selector(ejectClicked)
        ejectButton.isHidden = true

        addSubview(iconView)
        addSubview(statusDot)
        addSubview(statusSpinner)
        addSubview(nameLabel)
        addSubview(subtitleLabel)
        addSubview(capacityLabel)
        addSubview(protocolBadge)
        addSubview(ejectButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            statusSpinner.centerXAnchor.constraint(equalTo: statusDot.centerXAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),
            statusSpinner.widthAnchor.constraint(equalToConstant: 12),
            statusSpinner.heightAnchor.constraint(equalToConstant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: capacityLabel.leadingAnchor, constant: -4),

            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            capacityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            capacityLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 50),

            protocolBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            // protocolBadge trailing is set dynamically based on eject button visibility

            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),
            ejectButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func configure(
        with item: SidebarItem,
        theme: Theme,
        indented: Bool = false,
        isOffline: Bool = false,
        hasVolumes: Bool = false,
        remoteConnectionState: SSHConnectionState? = nil
    ) {
        statusDot.isHidden = true
        statusSpinner.stopAnimation(nil)
        statusSpinner.isHidden = true
        subtitleLabel.isHidden = true
        alphaValue = 1.0

        switch item {
        case .section(let section):
            configureAsSection(section, theme: theme)
        case .device(let volume):
            configureAsDevice(volume, theme: theme)
        case .remoteHost(let host):
            configureAsRemoteHost(host, theme: theme, state: remoteConnectionState ?? .disconnected)
        case .server(let server):
            configureAsServer(server, theme: theme, isOffline: isOffline, hasVolumes: hasVolumes)
        case .syntheticServer(let synthetic):
            configureAsSyntheticServer(synthetic, theme: theme, hasVolumes: hasVolumes)
        case .networkVolume(let volume):
            configureAsNetworkVolume(volume, theme: theme, indented: indented)
        case .favorite(let url):
            configureAsFavorite(url, theme: theme)
        }
    }

    private func configureAsSection(_ section: SidebarSection, theme: Theme) {
        iconView.isHidden = true
        nameLabel.stringValue = section.title
        nameLabel.font = theme.uiFont(size: 11)
        nameLabel.textColor = theme.textSecondary
        capacityLabel.isHidden = true

        // Adjust leading constraint for section headers (no icon)
        if let constraint = constraints.first(where: { $0.firstAnchor == nameLabel.leadingAnchor }) {
            constraint.isActive = false
        }
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true

        // Offset content down by 6px to create top padding (row is 34px: 6px top + 28px content)
        for constraint in constraints where constraint.firstAnchor == nameLabel.centerYAnchor {
            constraint.isActive = false
        }
        nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3).isActive = true
    }

    private func configureAsDevice(_ volume: VolumeInfo, theme: Theme) {
        iconView.isHidden = false
        iconView.image = volume.icon
        nameLabel.stringValue = volume.name
        nameLabel.font = theme.uiFont(size: 13)
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

    private func configureAsServer(_ server: NetworkServer, theme: Theme, isOffline: Bool = false, hasVolumes: Bool = false) {
        iconView.isHidden = false
        let serverIcon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Server")
        iconView.image = serverIcon

        if isOffline {
            // Dimmed appearance for offline servers
            iconView.contentTintColor = theme.textTertiary
            nameLabel.textColor = theme.textTertiary
            protocolBadge.stringValue = "offline"
            alphaValue = 0.7
        } else {
            iconView.contentTintColor = theme.textSecondary
            nameLabel.textColor = theme.textPrimary
            protocolBadge.stringValue = server.protocol.displayName
            alphaValue = 1.0
        }

        nameLabel.stringValue = server.name
        nameLabel.font = theme.uiFont(size: 13)
        capacityLabel.isHidden = true

        // Show protocol/status badge
        protocolBadge.isHidden = false
        protocolBadge.font = theme.uiFont(size: 9)
        protocolBadge.textColor = theme.textTertiary

        // Show eject button when server has mounted volumes
        ejectButton.isHidden = !hasVolumes
        protocolBadgeTrailingConstraint?.isActive = false
        if hasVolumes {
            ejectButton.contentTintColor = theme.textSecondary
            ejectButton.alphaValue = 0.7
            // Move protocol badge to not overlap with eject button
            protocolBadgeTrailingConstraint = protocolBadge.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -6)
        } else {
            // Badge at trailing edge when no eject button
            protocolBadgeTrailingConstraint = protocolBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        }
        protocolBadgeTrailingConstraint?.isActive = true

        resetNameLeading()
    }

    private func configureAsRemoteHost(_ host: RemoteHost, theme: Theme, state: SSHConnectionState) {
        iconView.isHidden = true
        let isInProgress: Bool
        switch state {
        case .connecting, .reconnecting:
            isInProgress = true
        default:
            isInProgress = false
        }
        statusDot.isHidden = isInProgress
        statusDot.layer?.backgroundColor = statusDotColor(for: state, theme: theme).cgColor
        statusSpinner.isHidden = !isInProgress
        if isInProgress {
            statusSpinner.startAnimation(nil)
        }
        toolTip = statusTooltip(for: state)

        nameLabel.stringValue = host.displayName
        nameLabel.font = theme.uiFont(size: 13)
        nameLabel.textColor = theme.textPrimary

        subtitleLabel.isHidden = true
        subtitleLabel.stringValue = ""
        subtitleLabel.font = theme.uiFont(size: 10)
        subtitleLabel.textColor = theme.textTertiary

        capacityLabel.isHidden = true
        protocolBadge.isHidden = true
        ejectButton.isHidden = true
        resetNameLeadingToStatusDot()

        resetNameCenterY()
    }

    private func statusDotColor(for state: SSHConnectionState, theme: Theme) -> NSColor {
        switch state {
        case .connected:
            return NSColor.systemGreen
        case .connecting, .reconnecting:
            return NSColor.systemYellow
        case .disconnected:
            return theme.textTertiary
        case .failed:
            return NSColor.systemRed
        }
    }

    private func statusTooltip(for state: SSHConnectionState) -> String? {
        if case .failed(let reason) = state {
            return reason.displayMessage
        }
        return nil
    }

    private func configureAsSyntheticServer(_ server: SyntheticServer, theme: Theme, hasVolumes: Bool = false) {
        iconView.isHidden = false
        let serverIcon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Server")
        iconView.image = serverIcon
        iconView.contentTintColor = theme.textSecondary
        nameLabel.stringValue = server.displayName
        nameLabel.font = theme.uiFont(size: 13)
        nameLabel.textColor = theme.textPrimary
        capacityLabel.isHidden = true

        // Show "manual" badge instead of protocol
        protocolBadge.isHidden = false
        protocolBadge.stringValue = "manual"
        protocolBadge.font = theme.uiFont(size: 9)
        protocolBadge.textColor = theme.textTertiary

        // Show eject button when server has mounted volumes
        ejectButton.isHidden = !hasVolumes
        protocolBadgeTrailingConstraint?.isActive = false
        if hasVolumes {
            ejectButton.contentTintColor = theme.textSecondary
            ejectButton.alphaValue = 0.7
            // Move protocol badge to not overlap with eject button
            protocolBadgeTrailingConstraint = protocolBadge.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -6)
        } else {
            // Badge at trailing edge when no eject button
            protocolBadgeTrailingConstraint = protocolBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        }
        protocolBadgeTrailingConstraint?.isActive = true

        resetNameLeading()
    }

    private func configureAsNetworkVolume(_ volume: VolumeInfo, theme: Theme, indented: Bool) {
        iconView.isHidden = false
        // Use consistent icon for network shares with accent color
        let shareIcon = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "Network Share")
        iconView.image = shareIcon
        iconView.contentTintColor = theme.accent
        nameLabel.stringValue = volume.name
        nameLabel.font = theme.uiFont(size: 13)
        nameLabel.textColor = theme.textPrimary

        // Show eject button for ejectable network volumes
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

        // Subtle indent for child items - enough to show hierarchy without feeling nested
        resetNameLeading(indent: indented ? 8 : 0)
    }

    func configureAsPlaceholder(_ placeholder: NetworkPlaceholder, theme: Theme) {
        iconView.isHidden = true
        nameLabel.stringValue = placeholder.text
        nameLabel.font = theme.uiFont(size: 11)
        nameLabel.textColor = theme.textTertiary
        capacityLabel.isHidden = true
        protocolBadge.isHidden = true

        // Adjust leading constraint for placeholder (no icon, indented)
        for constraint in constraints where constraint.firstAnchor == nameLabel.leadingAnchor {
            constraint.isActive = false
        }
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
    }

    private func configureAsFavorite(_ url: URL, theme: Theme) {
        iconView.isHidden = false
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        nameLabel.font = theme.uiFont(size: 13)
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

    private func resetNameLeading(indent: CGFloat = 0) {
        // Reset leading constraint to be after icon with optional indent
        for constraint in constraints where constraint.firstAnchor == nameLabel.leadingAnchor {
            constraint.isActive = false
        }
        for constraint in constraints where constraint.firstAnchor == iconView.leadingAnchor {
            constraint.isActive = false
        }
        iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14 + indent).isActive = true
        nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8).isActive = true
    }

    private func resetNameLeadingToStatusDot() {
        for constraint in constraints where constraint.firstAnchor == nameLabel.leadingAnchor {
            constraint.isActive = false
        }
        nameLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8).isActive = true
    }

    private func resetNameCenterY(offset: CGFloat = 0) {
        for constraint in constraints where constraint.firstAnchor == nameLabel.centerYAnchor {
            constraint.isActive = false
        }
        nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: offset).isActive = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.image = nil
        iconView.isHidden = false
        iconView.contentTintColor = nil
        statusDot.isHidden = true
        statusDot.layer?.backgroundColor = nil
        toolTip = nil
        nameLabel.stringValue = ""
        subtitleLabel.stringValue = ""
        subtitleLabel.isHidden = true
        capacityLabel.stringValue = ""
        capacityLabel.isHidden = true
        protocolBadge.stringValue = ""
        protocolBadge.isHidden = true
        capacityTrailingConstraint?.isActive = false
        capacityTrailingConstraint = nil
        protocolBadgeTrailingConstraint?.isActive = false
        protocolBadgeTrailingConstraint = nil
        ejectButton.isHidden = true
        ejectButton.alphaValue = 1.0
        alphaValue = 1.0
        onEject = nil

        // Reset icon leading to default position
        for constraint in constraints where constraint.firstAnchor == iconView.leadingAnchor {
            constraint.isActive = false
        }
        iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
    }
}
