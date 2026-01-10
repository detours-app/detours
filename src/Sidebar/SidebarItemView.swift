import AppKit

final class SidebarItemView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let capacityLabel = NSTextField(labelWithString: "")

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

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(capacityLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: capacityLabel.leadingAnchor, constant: -4),

            capacityLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            capacityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            capacityLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 50),
        ])
    }

    func configure(with item: SidebarItem, theme: Theme) {
        switch item {
        case .section(let section):
            configureAsSection(section, theme: theme)
        case .device(let volume):
            configureAsDevice(volume, theme: theme)
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
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
    }

    private func configureAsDevice(_ volume: VolumeInfo, theme: Theme) {
        iconView.isHidden = false
        iconView.image = volume.icon
        nameLabel.stringValue = volume.name
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = theme.textPrimary

        if let capacity = volume.capacityString {
            capacityLabel.isHidden = false
            capacityLabel.stringValue = capacity
            capacityLabel.textColor = theme.textTertiary
        } else {
            capacityLabel.isHidden = true
        }

        resetNameLeading()
    }

    private func configureAsFavorite(_ url: URL, theme: Theme) {
        iconView.isHidden = false
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        nameLabel.font = .systemFont(ofSize: 12)
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
        nameLabel.stringValue = ""
        capacityLabel.stringValue = ""
        capacityLabel.isHidden = true
    }
}
