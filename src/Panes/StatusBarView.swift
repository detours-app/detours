import AppKit

/// Status bar view displayed at the bottom of each pane
/// Shows: item count, selection info, selection size, hidden file count, available disk space
/// Progress mode: inline progress bar + operation text during file operations
final class StatusBarView: NSView {
    enum Mode {
        case normal
        case progress
        case paused
        case completion
        case error
    }

    private(set) var mode: Mode = .normal

    // Normal mode views
    private let label = NSTextField(labelWithString: "")

    // Progress mode views
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")

    // State
    private var itemCount: Int = 0
    private var selectedCount: Int = 0
    private var hiddenCount: Int = 0
    private var selectionSize: Int64 = 0
    private var availableSpace: Int64 = 0
    private var completionWorkItem: DispatchWorkItem?
    let speedCalculator = TransferSpeedCalculator()

    private var isDestination = false
    var onProgressClick: (() -> Void)?

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

        // Normal label
        label.font = theme.uiFont(size: ThemeManager.shared.fontSize - 1)
        label.textColor = theme.textSecondary
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        // Progress bar (horizontal, small)
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        addSubview(progressBar)

        // Progress label
        progressLabel.font = theme.uiFont(size: ThemeManager.shared.fontSize - 1)
        progressLabel.textColor = theme.textSecondary
        progressLabel.lineBreakMode = .byTruncatingMiddle
        progressLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressLabel.isHidden = true
        addSubview(progressLabel)

        // Layout
        label.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Normal label
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Progress bar at leading edge
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            progressBar.widthAnchor.constraint(equalToConstant: 100),
            progressBar.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Progress label fills remaining space
            progressLabel.leadingAnchor.constraint(equalTo: progressBar.trailingAnchor, constant: 8),
            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Accessibility
        progressBar.setAccessibilityRole(.progressIndicator)
        progressBar.setAccessibilityLabel("File operation progress")
        progressLabel.setAccessibilityRole(.staticText)

        // Click handler
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

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
        label.font = theme.uiFont(size: ThemeManager.shared.fontSize - 1)

        switch mode {
        case .normal:
            label.textColor = theme.textSecondary
        case .progress:
            progressLabel.font = theme.uiFont(size: ThemeManager.shared.fontSize - 1)
            progressLabel.textColor = theme.textSecondary
        case .paused:
            label.textColor = theme.textSecondary
        case .completion:
            label.textColor = theme.accent
        case .error:
            label.textColor = .systemRed
        }

        progressLabel.font = theme.uiFont(size: ThemeManager.shared.fontSize - 1)
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

    func showProgress(_ progress: FileOperationProgress, isDestination: Bool = false) {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        mode = .progress
        self.isDestination = isDestination

        speedCalculator.reset()

        label.isHidden = true
        progressBar.isHidden = false
        progressLabel.isHidden = false

        updateProgressViews(progress)
    }

    func updateProgress(_ progress: FileOperationProgress) {
        guard case .progress = mode else { return }
        updateProgressViews(progress)
    }

    func showPaused(message: String) {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        mode = .paused

        progressBar.isHidden = true
        progressLabel.isHidden = true
        label.isHidden = false

        label.stringValue = message
        label.textColor = ThemeManager.shared.currentTheme.textSecondary
        label.lineBreakMode = .byTruncatingMiddle
        needsDisplay = true

        postAccessibilityAnnouncement(message)
    }

    func showCompletion(message: String) {
        completionWorkItem?.cancel()
        mode = .completion

        progressBar.isHidden = true
        progressLabel.isHidden = true
        label.isHidden = false

        label.stringValue = message
        label.textColor = ThemeManager.shared.currentTheme.accent
        needsDisplay = true

        postAccessibilityAnnouncement("Operation complete")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showNormal()
        }
        completionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }

    func showError(message: String) {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        mode = .error

        progressBar.isHidden = true
        progressLabel.isHidden = true
        label.isHidden = false

        label.stringValue = message
        label.textColor = .systemRed
        label.lineBreakMode = .byTruncatingMiddle
        needsDisplay = true

        postAccessibilityAnnouncement("Operation failed")
    }

    private func postAccessibilityAnnouncement(_ message: String) {
        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: userInfo)
    }

    func showNormal() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        mode = .normal

        progressBar.isHidden = true
        progressLabel.isHidden = true
        label.isHidden = false

        label.textColor = ThemeManager.shared.currentTheme.textSecondary
        label.lineBreakMode = .byTruncatingMiddle
        updateLabel()
        needsDisplay = true
    }

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

        if case .normal = mode {
            updateLabel()
        }
    }

    // MARK: - Private

    @objc private func handleClick(_ sender: Any?) {
        switch mode {
        case .progress, .paused, .error:
            onProgressClick?()
        case .normal, .completion:
            break
        }
    }

    private func updateProgressViews(_ progress: FileOperationProgress) {
        let fraction = progress.fractionCompleted

        // Update progress bar
        if progress.totalCount == 0 && progress.bytesTotal == 0 {
            // Indeterminate
            if !progressBar.isIndeterminate {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
        } else {
            if progressBar.isIndeterminate {
                progressBar.isIndeterminate = false
                progressBar.stopAnimation(nil)
            }
            progressBar.doubleValue = fraction
        }

        // Update speed calculator with bytes
        if progress.bytesTotal > 0 {
            speedCalculator.addSample(bytesCompleted: progress.bytesCompleted)
        }

        // Format progress text
        progressLabel.stringValue = formatProgressText(progress)
    }

    func formatProgressText(_ progress: FileOperationProgress) -> String {
        let verb: String
        if isDestination, progress.operation.destinationURL != nil {
            verb = "Receiving"
        } else {
            verb = progress.operation.verb
        }
        let count = progress.operation.itemCount
        let itemWord = count == 1 ? "item" : "items"

        // Indeterminate: "Scanning..."
        if progress.totalCount == 0 && progress.bytesTotal == 0 {
            return "Scanning..."
        }

        // Byte-level progress: "Copying 1 item · 47% · 2.1 GB of 4.5 GB · 16 MB/s · 3 min left"
        if progress.bytesTotal > 0 {
            let percent = Int(progress.fractionCompleted * 100)
            let completed = formatSize(progress.bytesCompleted)
            let total = formatSize(progress.bytesTotal)
            var text = "\(verb) \(count) \(itemWord) · \(percent)% · \(completed) of \(total)"

            if let speed = speedCalculator.currentSpeed, speed > 0 {
                text += " · \(formatSpeed(speed))"
                let remaining = Double(progress.bytesTotal - progress.bytesCompleted)
                let seconds = remaining / speed
                if seconds >= 1 {
                    text += " · \(formatETA(seconds))"
                }
            }

            return text
        }

        // Item-count progress: "Moving 3 items · 2 of 5"
        return "\(verb) \(count) \(itemWord) · \(progress.completedCount) of \(progress.totalCount)"
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
            return String(format: "%.0f KB", kb)
        } else if size < 1_000_000_000 {
            let mb = Double(size) / 1_000_000
            return String(format: "%.0f MB", mb)
        } else if size < 1_000_000_000_000 {
            let gb = Double(size) / 1_000_000_000
            return String(format: "%.1f GB", gb)
        } else {
            let tb = Double(size) / 1_000_000_000_000
            return String(format: "%.1f TB", tb)
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds)) sec left"
        } else if seconds < 3600 {
            let min = Int(seconds / 60)
            return "\(min) min left"
        } else {
            let hr = Int(seconds / 3600)
            let min = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return min > 0 ? "\(hr) hr \(min) min left" : "\(hr) hr left"
        }
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_000_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1000)
        } else if bytesPerSecond < 1_000_000_000 {
            return String(format: "%.0f MB/s", bytesPerSecond / 1_000_000)
        } else {
            return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        }
    }
}

// MARK: - Transfer Speed Calculator

/// Calculates transfer speed from bytes over a rolling 2-second window
final class TransferSpeedCalculator {
    private struct Sample {
        let timestamp: CFAbsoluteTime
        let bytes: Int64
    }

    private var samples: [Sample] = []
    private let windowDuration: CFAbsoluteTime = 2.0

    var currentSpeed: Double? {
        pruneOldSamples()
        guard samples.count >= 2 else { return nil }

        let oldest = samples.first!
        let newest = samples.last!
        let elapsed = newest.timestamp - oldest.timestamp

        guard elapsed >= 0.5 else { return nil }

        let bytesDelta = Double(newest.bytes - oldest.bytes)
        guard bytesDelta > 0 else { return nil }

        return bytesDelta / elapsed
    }

    func addSample(bytesCompleted: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        samples.append(Sample(timestamp: now, bytes: bytesCompleted))
        pruneOldSamples()
    }

    func reset() {
        samples.removeAll()
    }

    private func pruneOldSamples() {
        let cutoff = CFAbsoluteTimeGetCurrent() - windowDuration
        samples.removeAll { $0.timestamp < cutoff }
    }
}
