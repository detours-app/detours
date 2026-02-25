import AppKit
import QuartzCore

@MainActor
final class ActivityToolbarButton: NSView {
    enum State {
        case idle
        case indeterminate
        case active(fraction: Double)
        case completing
        case error
    }

    private(set) var state: State = .idle

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let iconView = NSImageView()

    private let ringDiameter: CGFloat = 22
    private let ringLineWidth: CGFloat = 2.5
    private let buttonSize: CGFloat = 28

    private var completingWorkItem: DispatchWorkItem?
    private var iconSpinTimer: Timer?

    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize))
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        let theme = ThemeManager.shared.currentTheme
        let center = CGPoint(x: buttonSize / 2, y: buttonSize / 2)
        let radius = ringDiameter / 2

        let circlePath = CGMutablePath()
        circlePath.addArc(
            center: center,
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: 3 * .pi / 2,
            clockwise: false
        )

        let layerFrame = CGRect(x: 0, y: 0, width: buttonSize, height: buttonSize)

        // Track layer (full circle, subtle) — only visible during determinate progress
        trackLayer.frame = layerFrame
        trackLayer.path = circlePath
        trackLayer.strokeColor = theme.border.cgColor
        trackLayer.fillColor = nil
        trackLayer.lineWidth = ringLineWidth
        trackLayer.lineCap = .round
        trackLayer.isHidden = true
        layer?.addSublayer(trackLayer)

        // Progress layer (fills clockwise) — only visible during determinate progress
        progressLayer.frame = layerFrame
        progressLayer.path = circlePath
        progressLayer.strokeColor = theme.accent.cgColor
        progressLayer.fillColor = nil
        progressLayer.lineWidth = ringLineWidth
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        progressLayer.isHidden = true
        layer?.addSublayer(progressLayer)

        // Center icon — accent-colored, rotates during indeterminate
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Activity")?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = theme.accent
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: buttonSize),
            heightAnchor.constraint(equalToConstant: buttonSize),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("File operation progress")
    }

    // MARK: - Public API

    func startProgress(indeterminate: Bool) {
        completingWorkItem?.cancel()
        completingWorkItem = nil

        let theme = ThemeManager.shared.currentTheme
        iconView.contentTintColor = theme.accent
        setActivityIcon()

        if indeterminate {
            state = .indeterminate
            trackLayer.isHidden = true
            progressLayer.isHidden = true
            startIconSpin()
        } else {
            state = .active(fraction: 0)
            stopIconSpin()
            trackLayer.isHidden = false
            progressLayer.isHidden = false
            progressLayer.strokeEnd = 0
            progressLayer.strokeColor = theme.accent.cgColor
        }

        setAccessibilityValue(indeterminate ? "In progress" : "0%")
    }

    func updateProgress(_ fraction: Double) {
        stopIconSpin()
        state = .active(fraction: fraction)

        trackLayer.isHidden = false
        progressLayer.isHidden = false

        let clamped = min(max(fraction, 0), 1)

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
        animation.toValue = clamped
        animation.duration = 0.15
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        progressLayer.strokeEnd = clamped
        progressLayer.add(animation, forKey: "progressAnimation")

        setAccessibilityValue("\(Int(clamped * 100))%")
    }

    func showCompleting() {
        state = .completing
        stopIconSpin()

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
        animation.toValue = 1.0
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        progressLayer.strokeEnd = 1.0
        progressLayer.add(animation, forKey: "completeAnimation")

        setAccessibilityValue("Complete")
        postAccessibilityAnnouncement("Operation complete")
    }

    func showError() {
        state = .error
        stopIconSpin()
        completingWorkItem?.cancel()
        completingWorkItem = nil

        trackLayer.isHidden = true
        progressLayer.isHidden = true

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error")?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = NSColor.systemRed

        setAccessibilityValue("Error")
        postAccessibilityAnnouncement("Operation failed")
    }

    func reset() {
        state = .idle
        stopIconSpin()
        completingWorkItem?.cancel()
        completingWorkItem = nil

        trackLayer.isHidden = true
        progressLayer.isHidden = true
        progressLayer.strokeEnd = 0
        progressLayer.removeAllAnimations()

        setActivityIcon()
        iconView.contentTintColor = ThemeManager.shared.currentTheme.accent
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    // MARK: - Private

    private func setActivityIcon() {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Activity")?
            .withSymbolConfiguration(config)
    }

    private func startIconSpin() {
        guard iconSpinTimer == nil else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return
        }

        iconView.wantsLayer = true
        guard let iconLayer = iconView.layer else { return }

        // Set anchor point to center for rotation
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.position = CGPoint(x: iconView.frame.midX, y: iconView.frame.midY)

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 1.2
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        iconLayer.add(rotation, forKey: "iconSpin")
    }

    private func stopIconSpin() {
        iconSpinTimer?.invalidate()
        iconSpinTimer = nil
        iconView.layer?.removeAnimation(forKey: "iconSpin")
    }

    @objc private func handleClick(_ sender: Any?) {
        onClick?()
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
        trackLayer.strokeColor = theme.border.cgColor

        switch state {
        case .error:
            iconView.contentTintColor = NSColor.systemRed
        default:
            progressLayer.strokeColor = theme.accent.cgColor
            iconView.contentTintColor = theme.accent
        }
    }
}
