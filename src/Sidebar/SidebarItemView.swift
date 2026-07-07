import AppKit

final class SidebarItemView: NSTableCellView {
    private enum VolumeDisplayKind {
        case sparseBundle
        case diskImage
        case networkShare
        case localDevice

        var name: String {
            switch self {
            case .sparseBundle: return "mounted sparse bundle"
            case .diskImage: return "mounted disk image"
            case .networkShare: return "mounted file server"
            case .localDevice: return "local device"
            }
        }

        var symbolName: String {
            switch self {
            case .sparseBundle: return "externaldrive.fill"
            case .diskImage: return "externaldrive"
            case .networkShare: return "externaldrive.connected.to.line.below"
            case .localDevice: return "externaldrive"
            }
        }
    }

    private enum Layout {
        static let iconLeading: CGFloat = 12
        static let sectionLeading: CGFloat = 14
        static let childIndent: CGFloat = 10
        static let nameIconGap: CGFloat = 8
        static let trailingInset: CGFloat = -10
        static let accessoryTrailingInset: CGFloat = -8
    }

    private let iconView = NSImageView()
    private let statusDot = NSView()
    private let statusSpinner = NSProgressIndicator()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let capacityLabel = NSTextField(labelWithString: "")
    private let protocolBadge = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()
    private var nameTrailingConstraint: NSLayoutConstraint?
    private var capacityTrailingConstraint: NSLayoutConstraint?
    private var protocolBadgeTrailingConstraint: NSLayoutConstraint?
    private var accessoryTrailingConstraint: NSLayoutConstraint?

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
        nameLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 10)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isHidden = true

        capacityLabel.translatesAutoresizingMaskIntoConstraints = false
        capacityLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 10)
        capacityLabel.alignment = .right
        capacityLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        protocolBadge.translatesAutoresizingMaskIntoConstraints = false
        protocolBadge.font = ThemeManager.shared.currentTheme.uiFont(size: 9, weight: .medium)
        protocolBadge.alignment = .right
        protocolBadge.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        protocolBadge.lineBreakMode = .byTruncatingTail
        protocolBadge.isHidden = true

        // Accessory button setup
        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.bezelStyle = .inline
        ejectButton.isBordered = false
        ejectButton.imageScaling = .scaleProportionallyDown
        ejectButton.imagePosition = .imageOnly
        ejectButton.target = self
        ejectButton.action = #selector(accessoryClicked)
        ejectButton.isHidden = true
        configureAccessoryButton(symbolName: "eject.fill", accessibilityDescription: "Eject")

        addSubview(iconView)
        addSubview(statusDot)
        addSubview(statusSpinner)
        addSubview(nameLabel)
        addSubview(subtitleLabel)
        addSubview(capacityLabel)
        addSubview(protocolBadge)
        addSubview(ejectButton)

        nameTrailingConstraint = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: capacityLabel.leadingAnchor, constant: -4)
        accessoryTrailingConstraint = ejectButton.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: Layout.accessoryTrailingInset
        )

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.iconLeading),
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

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Layout.nameIconGap),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameTrailingConstraint!,

            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            capacityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            capacityLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 56),

            protocolBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            // protocolBadge trailing is set dynamically based on eject button visibility

            accessoryTrailingConstraint!,
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
        capacityLabel.isHidden = true
        protocolBadge.isHidden = true
        ejectButton.isHidden = true
        onEject = nil
        setNameTrailing(to: capacityLabel.leadingAnchor, constant: -4)
        setAccessoryTrailing(Layout.accessoryTrailingInset)
        resetNameCenterY()
        toolTip = nil
        setAccessibilityLabel(nil)
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
        nameLabel.font = theme.uiFont(size: 10, weight: .semibold)
        nameLabel.textColor = theme.textTertiary
        capacityLabel.isHidden = true
        protocolBadge.isHidden = true
        ejectButton.isHidden = true
        toolTip = section.title
        setAccessibilityLabel(section.title)

        // Adjust leading constraint for section headers (no icon)
        if let constraint = constraints.first(where: { $0.firstAnchor == nameLabel.leadingAnchor }) {
            constraint.isActive = false
        }
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.sectionLeading).isActive = true

        // Offset content down by 6px to create top padding (row is 34px: 6px top + 28px content)
        for constraint in constraints where constraint.firstAnchor == nameLabel.centerYAnchor {
            constraint.isActive = false
        }
        nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4).isActive = true
    }

    private func configureAsDevice(_ volume: VolumeInfo, theme: Theme) {
        iconView.isHidden = false
        let displayKind = volumeDisplayKind(for: volume, isNetworkVolume: false)
        if displayKind == .localDevice {
            iconView.image = volume.icon
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(systemSymbolName: displayKind.symbolName, accessibilityDescription: displayKind.name)
            iconView.contentTintColor = theme.accent
        }
        nameLabel.stringValue = volume.name
        nameLabel.font = theme.uiFont(size: 13)
        nameLabel.textColor = theme.textPrimary

        // Show eject button for ejectable volumes
        ejectButton.isHidden = !volume.isEjectable
        configureAccessoryButton(symbolName: "eject.fill", accessibilityDescription: "Eject \(volume.name)")
        setAccessoryTrailing(Layout.accessoryTrailingInset)
        setNameTrailing(to: capacityLabel.leadingAnchor, constant: -4)
        applyAccessoryTint(theme)

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
            capacityLabel.font = theme.uiFont(size: 10)
            capacityLabel.textColor = theme.textTertiary
        } else {
            capacityLabel.isHidden = true
        }

        let descriptor = "\(volume.name), \(displayKind.name)"
        toolTip = volumeToolTip(for: volume, kind: displayKind)
        setAccessibilityLabel(volume.isEjectable ? "\(descriptor), ejectable" : descriptor)
        resetNameLeading()
    }

    @objc private func accessoryClicked() {
        onEject?()
    }

    private func configureAccessoryButton(symbolName: String, accessibilityDescription: String) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
        let smallConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        ejectButton.image = image?.withSymbolConfiguration(smallConfig)
        ejectButton.toolTip = accessibilityDescription
        ejectButton.setAccessibilityLabel(accessibilityDescription)
    }

    private func applyAccessoryTint(_ theme: Theme) {
        ejectButton.contentTintColor = theme.textSecondary
        ejectButton.alphaValue = 0.82
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
        protocolBadge.textColor = isOffline ? theme.textTertiary : theme.accent.withAlphaComponent(0.85)

        // Show eject button when server has mounted volumes
        ejectButton.isHidden = !hasVolumes
        configureAccessoryButton(symbolName: "eject.fill", accessibilityDescription: "Eject mounted shares from \(server.name)")
        setAccessoryTrailing(Layout.accessoryTrailingInset)
        setNameTrailing(to: protocolBadge.leadingAnchor, constant: -4)
        protocolBadgeTrailingConstraint?.isActive = false
        if hasVolumes {
            applyAccessoryTint(theme)
            // Move protocol badge to not overlap with eject button
            protocolBadgeTrailingConstraint = protocolBadge.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -6)
        } else {
            // Badge at trailing edge when no eject button
            protocolBadgeTrailingConstraint = protocolBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        }
        protocolBadgeTrailingConstraint?.isActive = true

        toolTip = isOffline ? "\(server.name) is offline" : "\(server.name) \(server.protocol.displayName) file server"
        setAccessibilityLabel(hasVolumes ? "\(server.name), file server, mounted shares ejectable" : "\(server.name), file server")
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
        statusDot.layer?.borderWidth = 1
        statusDot.layer?.borderColor = theme.surface.withAlphaComponent(0.9).cgColor
        statusSpinner.isHidden = !isInProgress
        if isInProgress {
            statusSpinner.startAnimation(nil)
        }
        toolTip = statusTooltip(for: state) ?? "\(host.displayName), remote host"

        nameLabel.stringValue = host.displayName
        nameLabel.font = theme.uiFont(size: 13)
        nameLabel.textColor = theme.textPrimary

        subtitleLabel.isHidden = true
        subtitleLabel.stringValue = ""
        subtitleLabel.font = theme.uiFont(size: 10)
        subtitleLabel.textColor = theme.textTertiary

        capacityLabel.isHidden = true
        protocolBadge.isHidden = true
        ejectButton.isHidden = false
        configureAccessoryButton(symbolName: "minus.circle", accessibilityDescription: "Remove \(host.displayName)")
        setAccessoryTrailing(Layout.accessoryTrailingInset)
        setNameTrailing(to: ejectButton.leadingAnchor, constant: -4)
        applyAccessoryTint(theme)

        setAccessibilityLabel("\(host.displayName), remote host, \(statusAccessibilityDescription(for: state)), removable")
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

    private func statusAccessibilityDescription(for state: SSHConnectionState) -> String {
        switch state {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .reconnecting:
            return "reconnecting"
        case .disconnected:
            return "disconnected"
        case .failed:
            return "connection failed"
        }
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

        protocolBadge.isHidden = false
#if DETOURS_SCREENSHOT_FIXTURES
        protocolBadge.stringValue = server.protocolLabel ?? "manual"
#else
        protocolBadge.stringValue = "manual"
#endif
        protocolBadge.font = theme.uiFont(size: 9)
        protocolBadge.textColor = theme.accent.withAlphaComponent(0.85)

        // Show eject button when server has mounted volumes
        ejectButton.isHidden = !hasVolumes
        configureAccessoryButton(symbolName: "eject.fill", accessibilityDescription: "Eject mounted shares from \(server.displayName)")
        setAccessoryTrailing(Layout.accessoryTrailingInset)
        setNameTrailing(to: protocolBadge.leadingAnchor, constant: -4)
        protocolBadgeTrailingConstraint?.isActive = false
        if hasVolumes {
            applyAccessoryTint(theme)
            // Move protocol badge to not overlap with eject button
            protocolBadgeTrailingConstraint = protocolBadge.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -6)
        } else {
            // Badge at trailing edge when no eject button
            protocolBadgeTrailingConstraint = protocolBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        }
        protocolBadgeTrailingConstraint?.isActive = true

        toolTip = "\(server.displayName), mounted file server"
        setAccessibilityLabel(hasVolumes ? "\(server.displayName), mounted file server, shares ejectable" : "\(server.displayName), file server")
        resetNameLeading()
    }

    private func configureAsNetworkVolume(_ volume: VolumeInfo, theme: Theme, indented: Bool) {
        iconView.isHidden = false
        let displayKind = volumeDisplayKind(for: volume, isNetworkVolume: true)
        let shareIcon = NSImage(systemSymbolName: displayKind.symbolName, accessibilityDescription: displayKind.name)
        iconView.image = shareIcon
        iconView.contentTintColor = theme.accent
        nameLabel.stringValue = volume.name
        nameLabel.font = theme.uiFont(size: 13)
        nameLabel.textColor = theme.textPrimary

        // Show eject button for ejectable network volumes
        ejectButton.isHidden = !volume.isEjectable
        configureAccessoryButton(symbolName: "eject.fill", accessibilityDescription: "Eject \(volume.name)")
        setAccessoryTrailing(Layout.accessoryTrailingInset)
        setNameTrailing(to: capacityLabel.leadingAnchor, constant: -4)
        applyAccessoryTint(theme)

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
            capacityLabel.font = theme.uiFont(size: 10)
            capacityLabel.textColor = theme.textTertiary
        } else {
            capacityLabel.isHidden = true
        }

        let descriptor = "\(volume.name), \(displayKind.name)"
        toolTip = volumeToolTip(for: volume, kind: displayKind)
        setAccessibilityLabel(volume.isEjectable ? "\(descriptor), ejectable" : descriptor)
        // Subtle indent for child items - enough to show hierarchy without feeling nested
        resetNameLeading(indent: indented ? Layout.childIndent : 0)
    }

    func configureAsPlaceholder(_ placeholder: NetworkPlaceholder, theme: Theme) {
        iconView.isHidden = true
        nameLabel.stringValue = placeholder.text
        nameLabel.font = theme.uiFont(size: 11)
        nameLabel.textColor = theme.textTertiary
        capacityLabel.isHidden = true
        protocolBadge.isHidden = true
        toolTip = placeholder.text
        setAccessibilityLabel(placeholder.text)

        // Adjust leading constraint for placeholder (no icon, indented)
        for constraint in constraints where constraint.firstAnchor == nameLabel.leadingAnchor {
            constraint.isActive = false
        }
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.sectionLeading).isActive = true
    }

    private func configureAsFavorite(_ url: URL, theme: Theme) {
        iconView.isHidden = false
        nameLabel.font = theme.uiFont(size: 13)
        capacityLabel.isHidden = true
        ejectButton.isHidden = false
        configureAccessoryButton(symbolName: "minus.circle", accessibilityDescription: "Remove \(url.lastPathComponent) from Favorites")
        setAccessoryTrailing(Layout.accessoryTrailingInset)
        setNameTrailing(to: ejectButton.leadingAnchor, constant: -4)
        applyAccessoryTint(theme)

        // Check if favorite exists
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path) {
            nameLabel.stringValue = url.lastPathComponent
            nameLabel.textColor = theme.textPrimary
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        } else {
            nameLabel.stringValue = url.lastPathComponent
            nameLabel.textColor = theme.textTertiary
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconView.image = isDirectory.boolValue ? FileItem.tintedFolderIcon(icon) : icon
        iconView.contentTintColor = nil

        toolTip = url.path
        setAccessibilityLabel(FileManager.default.fileExists(atPath: url.path) ? "\(url.lastPathComponent), favorite, removable" : "\(url.lastPathComponent), missing favorite, removable")
        resetNameLeading()
    }

    private func volumeDisplayKind(for volume: VolumeInfo, isNetworkVolume: Bool) -> VolumeDisplayKind {
        if isNetworkVolume || volume.isNetwork {
            return .networkShare
        }

        let lowerName = volume.name.lowercased()
        let lowerPath = volume.url.path.lowercased()
        if lowerName.contains("sparsebundle") || lowerPath.contains("sparsebundle") {
            return .sparseBundle
        }
        if lowerName.contains(".dmg") || lowerPath.contains(".dmg") ||
            lowerName.contains(".sparseimage") || lowerPath.contains(".sparseimage") ||
            lowerName.contains(".iso") || lowerPath.contains(".iso") {
            return .diskImage
        }
        return .localDevice
    }

    private func volumeToolTip(for volume: VolumeInfo, kind: VolumeDisplayKind) -> String {
        var parts = ["\(volume.name), \(kind.name)"]
        if let capacity = volume.capacityString {
            parts.append("\(capacity) available")
        }
        if volume.isEjectable {
            parts.append("ejectable")
        }
        return parts.joined(separator: ", ")
    }

    private func setNameTrailing(to anchor: NSLayoutXAxisAnchor, constant: CGFloat) {
        nameTrailingConstraint?.isActive = false
        nameTrailingConstraint = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: anchor, constant: constant)
        nameTrailingConstraint?.isActive = true
    }

    private func setAccessoryTrailing(_ constant: CGFloat) {
        accessoryTrailingConstraint?.isActive = false
        accessoryTrailingConstraint = ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: constant)
        accessoryTrailingConstraint?.isActive = true
    }

    private func resetNameLeading(indent: CGFloat = 0) {
        // Reset leading constraint to be after icon with optional indent
        for constraint in constraints where constraint.firstAnchor == nameLabel.leadingAnchor {
            constraint.isActive = false
        }
        for constraint in constraints where constraint.firstAnchor == iconView.leadingAnchor {
            constraint.isActive = false
        }
        iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.iconLeading + indent).isActive = true
        nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Layout.nameIconGap).isActive = true
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
        statusDot.layer?.borderWidth = 0
        statusDot.layer?.borderColor = nil
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
        setNameTrailing(to: capacityLabel.leadingAnchor, constant: -4)
        setAccessoryTrailing(Layout.accessoryTrailingInset)
        ejectButton.isHidden = true
        ejectButton.alphaValue = 1.0
        alphaValue = 1.0
        onEject = nil

        // Reset icon leading to default position
        for constraint in constraints where constraint.firstAnchor == iconView.leadingAnchor {
            constraint.isActive = false
        }
        iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.iconLeading).isActive = true
    }
}
