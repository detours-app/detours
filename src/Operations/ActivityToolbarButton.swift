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

    private let ringDiameter: CGFloat = 18
    private let ringLineWidth: CGFloat = 1.5
    private let buttonSize: CGFloat = 32

    private var completingWorkItem: DispatchWorkItem?

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

        // Track layer (full circle) — always visible, faint
        trackLayer.frame = layerFrame
        trackLayer.path = circlePath
        trackLayer.strokeColor = theme.accent.withAlphaComponent(0.08).cgColor
        trackLayer.fillColor = nil
        trackLayer.lineWidth = ringLineWidth
        trackLayer.lineCap = .round
        trackLayer.opacity = 0.2
        layer?.addSublayer(trackLayer)

        // Progress layer (fills clockwise)
        progressLayer.frame = layerFrame
        progressLayer.path = circlePath
        progressLayer.strokeColor = theme.accent.cgColor
        progressLayer.fillColor = nil
        progressLayer.lineWidth = ringLineWidth
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        progressLayer.isHidden = true
        layer?.addSublayer(progressLayer)

        // Center icon — hidden in idle state
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Activity")?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = theme.accent
        iconView.imageScaling = .scaleProportionallyDown
        iconView.isHidden = true
        addSubview(iconView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
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
        progressLayer.strokeColor = theme.accent.cgColor

        if indeterminate {
            state = .indeterminate
            iconView.isHidden = true
            trackLayer.opacity = 1.0
            progressLayer.isHidden = false
            startTravelingArc()
        } else {
            state = .active(fraction: 0)
            iconView.isHidden = true
            stopTravelingArc()
            trackLayer.opacity = 1.0
            progressLayer.isHidden = false
            progressLayer.strokeStart = 0
            progressLayer.strokeEnd = 0
        }

        setAccessibilityValue(indeterminate ? "In progress" : "0%")
    }

    func updateProgress(_ fraction: Double) {
        stopTravelingArc()
        state = .active(fraction: fraction)

        iconView.isHidden = true
        trackLayer.opacity = 1.0
        progressLayer.isHidden = false
        progressLayer.strokeStart = 0

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
        stopTravelingArc()

        // Fill to 100%
        let fillAnimation = CABasicAnimation(keyPath: "strokeEnd")
        fillAnimation.fromValue = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
        fillAnimation.toValue = 1.0
        fillAnimation.duration = 0.2
        fillAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fillAnimation.isRemovedOnCompletion = false
        fillAnimation.fillMode = .forwards
        progressLayer.strokeEnd = 1.0
        progressLayer.add(fillAnimation, forKey: "completeAnimation")

        // Scale down and fade to idle after fill
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let delay = reduceMotion ? 0.2 : 0.3

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            if !reduceMotion {
                // Scale ring down
                let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                scaleAnim.fromValue = 1.0
                scaleAnim.toValue = 0.6
                scaleAnim.duration = 0.3
                scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scaleAnim.isRemovedOnCompletion = false
                scaleAnim.fillMode = .forwards
                self.progressLayer.add(scaleAnim, forKey: "scaleDown")
                if let copy = scaleAnim.copy() as? CAAnimation {
                    self.trackLayer.add(copy, forKey: "scaleDown")
                }
            }

            // Fade to idle opacity
            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 1.0
            fadeAnim.toValue = 0.2
            fadeAnim.duration = reduceMotion ? 0.15 : 0.3
            fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fadeAnim.isRemovedOnCompletion = false
            fadeAnim.fillMode = .forwards
            self.trackLayer.add(fadeAnim, forKey: "fadeToIdle")
            if let copy = fadeAnim.copy() as? CAAnimation {
                self.progressLayer.add(copy, forKey: "fadeToIdle")
            }

            // Reset to idle after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.15 : 0.3)) { [weak self] in
                self?.reset()
            }
        }
        completingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

        setAccessibilityValue("Complete")
        postAccessibilityAnnouncement("Operation complete")
    }

    func showError() {
        state = .error
        stopTravelingArc()
        completingWorkItem?.cancel()
        completingWorkItem = nil

        iconView.isHidden = true
        trackLayer.opacity = 1.0
        progressLayer.isHidden = false
        progressLayer.strokeStart = 0
        progressLayer.strokeEnd = 1.0

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Animate stroke color from accent to red
        let colorAnim = CABasicAnimation(keyPath: "strokeColor")
        colorAnim.fromValue = ThemeManager.shared.currentTheme.accent.cgColor
        colorAnim.toValue = NSColor.systemRed.cgColor
        colorAnim.duration = reduceMotion ? 0.0 : 0.25
        colorAnim.isRemovedOnCompletion = false
        colorAnim.fillMode = .forwards
        progressLayer.strokeColor = NSColor.systemRed.cgColor
        progressLayer.add(colorAnim, forKey: "errorColor")
        trackLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor

        // Pulse ring opacity (skip if reduce motion)
        if !reduceMotion {
            let pulseAnim = CAKeyframeAnimation(keyPath: "opacity")
            pulseAnim.values = [1.0, 0.4, 1.0]
            pulseAnim.keyTimes = [0, 0.5, 1.0]
            pulseAnim.duration = 0.4
            pulseAnim.beginTime = CACurrentMediaTime() + 0.25
            pulseAnim.isRemovedOnCompletion = false
            pulseAnim.fillMode = .forwards
            progressLayer.add(pulseAnim, forKey: "errorPulse")
        }

        setAccessibilityValue("Error")
        postAccessibilityAnnouncement("Operation failed")
    }

    func reset() {
        state = .idle
        stopTravelingArc()
        completingWorkItem?.cancel()
        completingWorkItem = nil

        iconView.isHidden = true
        progressLayer.isHidden = true
        progressLayer.strokeEnd = 0
        progressLayer.strokeStart = 0
        progressLayer.removeAllAnimations()
        trackLayer.removeAllAnimations()

        // Idle: faint ring at 20% opacity
        let theme = ThemeManager.shared.currentTheme
        trackLayer.opacity = 0.2
        trackLayer.strokeColor = theme.accent.withAlphaComponent(0.08).cgColor
        trackLayer.transform = CATransform3DIdentity
        progressLayer.transform = CATransform3DIdentity
        progressLayer.strokeColor = theme.accent.cgColor
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    // MARK: - Private

    private func startTravelingArc() {
        progressLayer.removeAllAnimations()
        progressLayer.strokeStart = 0
        progressLayer.strokeEnd = 0.02

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Static arc — no animation
            progressLayer.strokeEnd = 0.25
            return
        }

        // Keyframe animations: arc grows then shrinks each cycle.
        // At cycle boundaries the arc is near-zero, so the repeat reset is invisible.
        let endAnim = CAKeyframeAnimation(keyPath: "strokeEnd")
        endAnim.values = [0.02, 0.95, 0.95]
        endAnim.keyTimes = [0, 0.45, 1.0]
        endAnim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
        ]

        let startAnim = CAKeyframeAnimation(keyPath: "strokeStart")
        startAnim.values = [0.0, 0.0, 0.93]
        startAnim.keyTimes = [0, 0.45, 1.0]
        startAnim.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeIn),
        ]

        let group = CAAnimationGroup()
        group.animations = [startAnim, endAnim]
        group.duration = 1.4
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        progressLayer.add(group, forKey: "travelingArc")

        // Continuous rotation — slightly desynchronized from stroke cycle for organic feel
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 1.8
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        progressLayer.add(rotation, forKey: "arcRotation")
    }

    private func stopTravelingArc() {
        progressLayer.removeAnimation(forKey: "travelingArc")
        progressLayer.removeAnimation(forKey: "arcRotation")
        progressLayer.strokeStart = 0
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

        switch state {
        case .error:
            trackLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
            progressLayer.strokeColor = NSColor.systemRed.cgColor
        case .idle:
            trackLayer.strokeColor = theme.accent.withAlphaComponent(0.08).cgColor
            progressLayer.strokeColor = theme.accent.cgColor
        default:
            trackLayer.strokeColor = theme.accent.withAlphaComponent(0.08).cgColor
            progressLayer.strokeColor = theme.accent.cgColor
        }
    }
}
