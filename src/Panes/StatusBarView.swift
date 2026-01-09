import AppKit

/// Status bar view displayed at the bottom of each pane
/// Shows: item count, selection info, selection size, hidden file count, available disk space
final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")

    private var itemCount: Int = 0
    private var selectedCount: Int = 0
    private var hiddenCount: Int = 0
    private var selectionSize: Int64 = 0
    private var availableSpace: Int64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let theme = ThemeManager.shared.currentTheme

        label.font = theme.font(size: ThemeManager.shared.fontSize - 2)
        label.textColor = theme.textSecondary
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(label)

        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Observe theme changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )
    }

    @objc private func handleThemeChange() {
        let theme = ThemeManager.shared.currentTheme
        label.font = theme.font(size: ThemeManager.shared.fontSize - 2)
        label.textColor = theme.textSecondary
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw background matching surface color
        ThemeManager.shared.currentTheme.surface.setFill()
        bounds.fill()

        // Draw top border
        ThemeManager.shared.currentTheme.border.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: bounds.height))
        path.line(to: NSPoint(x: bounds.width, y: bounds.height))
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - Public API

    func update(
        itemCount: Int,
        selectedCount: Int,
        hiddenCount: Int,
        selectionSize: Int64,
        availableSpace: Int64
    ) {
        self.itemCount = itemCount
        self.selectedCount = selectedCount
        self.hiddenCount = hiddenCount
        self.selectionSize = selectionSize
        self.availableSpace = availableSpace

        updateLabel()
    }

    private func updateLabel() {
        var parts: [String] = []

        // Item count and selection
        if selectedCount > 0 {
            parts.append("\(selectedCount) of \(itemCount) selected")
        } else {
            let itemWord = itemCount == 1 ? "item" : "items"
            parts.append("\(itemCount) \(itemWord)")
        }

        // Selection size (only when items selected)
        if selectedCount > 0 && selectionSize > 0 {
            parts.append("\(formatSize(selectionSize)) selected")
        }

        // Hidden file count
        if hiddenCount > 0 {
            let hiddenWord = hiddenCount == 1 ? "hidden" : "hidden"
            parts.append("\(hiddenCount) \(hiddenWord)")
        }

        // Available disk space
        if availableSpace > 0 {
            parts.append("\(formatSize(availableSpace)) available")
        }

        label.stringValue = parts.joined(separator: "  ·  ")
    }

    private func formatSize(_ size: Int64) -> String {
        if size < 1000 {
            return "\(size) B"
        } else if size < 1_000_000 {
            let kb = Double(size) / 1000
            return String(format: "%.1f KB", kb)
        } else if size < 1_000_000_000 {
            let mb = Double(size) / 1_000_000
            return String(format: "%.1f MB", mb)
        } else if size < 1_000_000_000_000 {
            let gb = Double(size) / 1_000_000_000
            return String(format: "%.1f GB", gb)
        } else {
            let tb = Double(size) / 1_000_000_000_000
            return String(format: "%.1f TB", tb)
        }
    }
}
