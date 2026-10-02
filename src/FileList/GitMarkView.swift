import AppKit

extension GitStatus {
    /// Spoken and tooltip name for the mark; clean files have none.
    var markLabel: String? {
        switch self {
        case .modified: return "Modified in git"
        case .staged: return "Staged in git"
        case .untracked: return "Untracked"
        case .conflict: return "Conflict"
        case .clean: return nil
        }
    }
}

/// Shape-coded git state after a file name: modified circle, staged rounded square,
/// untracked ring and conflict diamond, so the state never depends on colour alone.
final class GitMarkView: NSView {
    static let markSize: CGFloat = 8

    var status: GitStatus = .clean {
        didSet {
            guard status != oldValue else { return }
            toolTip = status.markLabel
            setAccessibilityLabel(status.markLabel)
            isHidden = status == .clean
            needsDisplay = true
        }
    }

    var color: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.markSize, height: Self.markSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let path = Self.path(for: status, in: bounds) else { return }
        color.setFill()
        color.setStroke()
        if status == .untracked {
            path.lineWidth = 1.5
            path.stroke()
        } else {
            path.fill()
        }
    }

    /// The mark's outline for a state, centred in `rect`; nil for clean files.
    static func path(for status: GitStatus, in rect: NSRect) -> NSBezierPath? {
        let side = min(rect.width, rect.height, markSize)
        let box = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        switch status {
        case .modified:
            return NSBezierPath(ovalIn: box)
        case .staged:
            return NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
        case .untracked:
            return NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
        case .conflict:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: box.midX, y: box.maxY))
            path.line(to: NSPoint(x: box.maxX, y: box.midY))
            path.line(to: NSPoint(x: box.midX, y: box.minY))
            path.line(to: NSPoint(x: box.minX, y: box.midY))
            path.close()
            return path
        case .clean:
            return nil
        }
    }
}
