import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "filterbar")

@MainActor
protocol FilterBarDelegate: AnyObject {
    func filterBar(_ filterBar: FilterBarView, didChangeText text: String)
    func filterBarDidRequestClose(_ filterBar: FilterBarView)
    func filterBarDidRequestFocusList(_ filterBar: FilterBarView)
}

final class FilterBarView: NSView {
    weak var delegate: FilterBarDelegate?

    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    var filterText: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        // Search field
        searchField.placeholderString = "Filter"
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel
        searchField.font = ThemeManager.shared.currentFont
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("filterSearchField")

        // Count label
        countLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = ThemeManager.shared.currentTheme.textSecondary
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        addSubview(searchField)
        addSubview(countLabel)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])

        applyTheme()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        // Observe text changes in the search field
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(searchFieldTextDidChange),
            name: NSControl.textDidChangeNotification,
            object: searchField
        )
    }

    @objc private func searchFieldTextDidChange(_ notification: Notification) {
        delegate?.filterBar(self, didChangeText: searchField.stringValue)
    }

    @objc private func handleThemeChange() {
        applyTheme()
    }

    private func applyTheme() {
        let theme = ThemeManager.shared.currentTheme
        layer?.backgroundColor = theme.surface.cgColor
        countLabel.textColor = theme.textSecondary
        searchField.font = ThemeManager.shared.currentFont
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw bottom border
        let theme = ThemeManager.shared.currentTheme
        theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func updateCount(visible: Int, total: Int) {
        if searchField.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else {
            countLabel.stringValue = "\(visible) of \(total)"
        }
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    func clear() {
        searchField.stringValue = ""
        countLabel.stringValue = ""
    }
}

// MARK: - NSSearchFieldDelegate

extension FilterBarView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        logger.debug("controlTextDidChange delegate: '\(self.searchField.stringValue)'")
        delegate?.filterBar(self, didChangeText: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc pressed
            if searchField.stringValue.isEmpty {
                delegate?.filterBarDidRequestClose(self)
            } else {
                searchField.stringValue = ""
                delegate?.filterBar(self, didChangeText: "")
            }
            return true
        }

        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            // Down arrow - move focus to list
            delegate?.filterBarDidRequestFocusList(self)
            return true
        }

        return false
    }
}
