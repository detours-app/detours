import AppKit

@MainActor
final class ActivityStrip: NSView {
    enum State {
        case hidden
        case starting
        case active(fraction: Double)
        case completing
        case error(message: String)
    }

    private(set) var state: State = .hidden

    private let spinner = NSProgressIndicator()
    private let operationLabel = NSTextField(labelWithString: "")
    private let separatorDot = NSTextField(labelWithString: "·")
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let queueBadge = NSTextField(labelWithString: "")
    private let progressBar = NSView()
    private let progressFill = NSView()
    private let dismissButton = NSButton()

    private var heightConstraint: NSLayoutConstraint!
    private var progressWidthConstraint: NSLayoutConstraint!
    private var completingWorkItem: DispatchWorkItem?

    private var operationType: String = ""
    private var fileName: String = ""
    private var completedCount: Int = 0
    private var totalCount: Int = 0
    private var queuedCount: Int = 0

    var onClick: (() -> Void)?
    var onDismissError: (() -> Void)?

    static let stripHeight: CGFloat = 20

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

        // Spinner
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.isHidden = true

        // Labels
        let theme = ThemeManager.shared.currentTheme
        let fontSize = ThemeManager.shared.fontSize - 2
        for label in [operationLabel, separatorDot, fileNameLabel, countLabel, queueBadge] {
            label.font = theme.font(size: fontSize)
            label.textColor = theme.textSecondary
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        operationLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        separatorDot.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        queueBadge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        queueBadge.textColor = theme.textTertiary

        // Dismiss button (for error state)
        dismissButton.bezelStyle = .inline
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.imagePosition = .imageOnly
        dismissButton.isBordered = false
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
        dismissButton.isHidden = true

        // Progress bar
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = theme.border.cgColor
        progressFill.wantsLayer = true
        progressFill.layer?.backgroundColor = theme.accent.cgColor

        progressBar.addSubview(progressFill)

        for sub in [spinner, operationLabel, separatorDot, fileNameLabel, countLabel, queueBadge, dismissButton, progressBar] {
            addSubview(sub)
            sub.translatesAutoresizingMaskIntoConstraints = false
        }
        translatesAutoresizingMaskIntoConstraints = false

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Spinner
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),

            // Operation label
            operationLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            operationLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            // Separator dot
            separatorDot.leadingAnchor.constraint(equalTo: operationLabel.trailingAnchor, constant: 6),
            separatorDot.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            // File name
            fileNameLabel.leadingAnchor.constraint(equalTo: separatorDot.trailingAnchor, constant: 6),
            fileNameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            // Queue badge
            queueBadge.leadingAnchor.constraint(equalTo: fileNameLabel.trailingAnchor, constant: 6),
            queueBadge.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            // Count label (right-aligned)
            countLabel.trailingAnchor.constraint(equalTo: dismissButton.isHidden ? trailingAnchor : dismissButton.leadingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            // Prevent file name from overlapping count
            fileNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            // Dismiss button
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            dismissButton.widthAnchor.constraint(equalToConstant: 16),
            dismissButton.heightAnchor.constraint(equalToConstant: 16),

            // Progress bar
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),

            // Progress fill
            progressFill.leadingAnchor.constraint(equalTo: progressBar.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressBar.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressBar.bottomAnchor),
            progressWidthConstraint,
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        // Theme changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        // Keyboard
        setAccessibilityRole(.progressIndicator)
    }

    // MARK: - Public API

    func showStarting(operationType: String, totalCount: Int, queuedCount: Int) {
        self.operationType = operationType
        self.totalCount = totalCount
        self.completedCount = 0
        self.queuedCount = queuedCount
        self.fileName = ""

        operationLabel.stringValue = operationType
        fileNameLabel.stringValue = ""
        countLabel.stringValue = ""
        updateQueueBadge()

        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.isHidden = false
        dismissButton.isHidden = true
        progressFill.layer?.backgroundColor = ThemeManager.shared.currentTheme.accent.cgColor

        completingWorkItem?.cancel()
        completingWorkItem = nil

        state = .starting
        animateHeight(to: Self.stripHeight)

        let countDesc = totalCount > 0 ? "\(totalCount) items" : ""
        postAccessibilityAnnouncement("\(operationType) \(countDesc)")
    }

    func updateProgress(_ progress: FileOperationProgress, queuedCount: Int) {
        self.queuedCount = queuedCount
        completedCount = progress.completedCount
        totalCount = progress.totalCount

        operationLabel.stringValue = shortOperationLabel(progress.operation)
        if let item = progress.currentItem {
            fileName = item.lastPathComponent
            fileNameLabel.stringValue = fileName
        }
        updateQueueBadge()

        if totalCount > 0 {
            let fraction = progress.fractionCompleted
            state = .active(fraction: fraction)
            spinner.isIndeterminate = false
            progressWidthConstraint.constant = progressBar.bounds.width * fraction

            countLabel.stringValue = "\(completedCount) of \(totalCount)"
        } else {
            state = .starting
            spinner.isIndeterminate = true
            countLabel.stringValue = ""
        }

        updateWidthAdaptation()
        setAccessibilityValue(totalCount > 0 ? "\(Int(progress.fractionCompleted * 100))%" : "In progress")
    }

    func showCompleting() {
        state = .completing
        progressWidthConstraint.constant = progressBar.bounds.width
        spinner.stopAnimation(nil)

        postAccessibilityAnnouncement("\(operationType) complete")

        let workItem = DispatchWorkItem { [weak self] in
            self?.collapse()
        }
        completingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    func showError(message: String) {
        state = .error(message: message)
        completingWorkItem?.cancel()
        completingWorkItem = nil

        operationLabel.stringValue = message
        operationLabel.textColor = errorTextColor
        fileNameLabel.stringValue = ""
        countLabel.stringValue = ""
        queueBadge.stringValue = ""
        separatorDot.isHidden = true
        dismissButton.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true

        progressFill.layer?.backgroundColor = errorTextColor.cgColor
        progressWidthConstraint.constant = progressBar.bounds.width

        setAccessibilityValue("Error: \(message)")
        postAccessibilityAnnouncement("Error: \(message)")
    }

    func collapse() {
        completingWorkItem?.cancel()
        completingWorkItem = nil
        state = .hidden
        animateHeight(to: 0)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.currentTheme
        theme.surface.setFill()
        bounds.fill()

        // Top border
        theme.border.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: bounds.height))
        path.line(to: NSPoint(x: bounds.width, y: bounds.height))
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        // Update progress width on resize
        if case let .active(fraction) = state {
            progressWidthConstraint.constant = progressBar.bounds.width * fraction
        }
        updateWidthAdaptation()
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49: // Return, Space
            handleClick(nil)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Private

    private func animateHeight(to value: CGFloat) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            heightConstraint.constant = value
            isHidden = value == 0
            return
        }

        let duration = value > 0 ? 0.18 : 0.22
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = value > 0
                ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            self.heightConstraint.animator().constant = value
            self.superview?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, value == 0 else { return }
                self.isHidden = true
                self.resetLabels()
            }
        }

        if value > 0 {
            isHidden = false
        }
    }

    private func resetLabels() {
        let theme = ThemeManager.shared.currentTheme
        operationLabel.stringValue = ""
        operationLabel.textColor = theme.textSecondary
        fileNameLabel.stringValue = ""
        countLabel.stringValue = ""
        queueBadge.stringValue = ""
        separatorDot.isHidden = false
        dismissButton.isHidden = true
        spinner.isHidden = true
        progressWidthConstraint.constant = 0
    }

    private func updateWidthAdaptation() {
        let width = bounds.width

        // Compact (< 320pt): spinner + operation label only
        let showFileName = width >= 320
        let showCount = width >= 600

        separatorDot.isHidden = !showFileName
        fileNameLabel.isHidden = !showFileName
        countLabel.isHidden = !showCount

        // Also hide queue badge in compact mode
        if case .error = state {
            queueBadge.isHidden = true
        } else {
            queueBadge.isHidden = !showFileName || queuedCount == 0
        }
    }

    private func updateQueueBadge() {
        if queuedCount > 0 {
            queueBadge.stringValue = "+ \(queuedCount) queued"
        } else {
            queueBadge.stringValue = ""
        }
    }

    private func shortOperationLabel(_ operation: FileOperation) -> String {
        switch operation {
        case .copy: return "Copying"
        case .move: return "Moving"
        case .delete: return "Trashing"
        case .deleteImmediately: return "Deleting"
        case .rename: return "Renaming"
        case .duplicate: return "Duplicating"
        case .createFolder: return "Creating"
        case .createFile: return "Creating"
        case .archive: return "Archiving"
        case .extract: return "Extracting"
        }
    }

    private var errorTextColor: NSColor {
        NSColor.systemRed
    }

    @objc private func handleClick(_ sender: Any?) {
        if case .error = state {
            return
        }
        onClick?()
    }

    @objc private func handleDismiss() {
        onDismissError?()
        collapse()
    }

    private func postAccessibilityAnnouncement(_ message: String) {
        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            NSAccessibility.NotificationUserInfoKey(rawValue: NSAccessibility.NotificationUserInfoKey.announcement.rawValue): message,
            NSAccessibility.NotificationUserInfoKey(rawValue: NSAccessibility.NotificationUserInfoKey.priority.rawValue): NSAccessibilityPriorityLevel.high.rawValue,
        ]
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: userInfo)
    }

    @objc private func handleThemeChange() {
        let theme = ThemeManager.shared.currentTheme
        let fontSize = ThemeManager.shared.fontSize - 2
        for label in [operationLabel, separatorDot, fileNameLabel, countLabel] {
            label.font = theme.font(size: fontSize)
            if case .error = state {
                // Don't reset error color
            } else {
                label.textColor = theme.textSecondary
            }
        }
        queueBadge.font = theme.font(size: fontSize)
        queueBadge.textColor = theme.textTertiary
        progressBar.layer?.backgroundColor = theme.border.cgColor
        if case .error = state {
            progressFill.layer?.backgroundColor = errorTextColor.cgColor
        } else {
            progressFill.layer?.backgroundColor = theme.accent.cgColor
        }
        needsDisplay = true
    }
}
