import AppKit

/// A plate behind a spinner that floats over content, so it stays legible over whatever is behind
/// it. A spinner drawn straight onto a dense page of text all but disappears.
///
/// This is for spinners that hover over other content. Spinners that sit inline in a row, such as a
/// folder being expanded or a sidebar item connecting, occupy their own space and are left plain.
final class SpinnerPlate: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            return shadow
        }()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(theme: Theme) {
        layer?.backgroundColor = theme.surface.cgColor
        layer?.borderColor = theme.border.cgColor
    }

    /// Wraps a spinner in a plate, centred, sized to leave room around it.
    static func wrapping(_ spinner: NSProgressIndicator, theme: Theme) -> SpinnerPlate {
        let plate = SpinnerPlate()
        plate.apply(theme: theme)
        plate.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(spinner)
        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: 78),
            plate.heightAnchor.constraint(equalToConstant: 78),
            spinner.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: plate.centerYAnchor)
        ])
        return plate
    }
}
