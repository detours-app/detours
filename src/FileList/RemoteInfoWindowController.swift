import AppKit

struct RemoteInfoSnapshot: Equatable {
    let name: String
    let kind: String
    let host: String
    let path: String
    let size: String
    let modified: String
    let hidden: String
    let readable: String
    let symlinkTarget: String?
}

@MainActor
final class RemoteInfoWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((RemoteInfoWindowController) -> Void)?

    private let snapshot: RemoteInfoSnapshot
    private let icon: NSImage

    init(snapshot: RemoteInfoSnapshot, icon: NSImage) {
        self.snapshot = snapshot
        self.icon = icon

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(snapshot.name) Info"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    private func makeContentView() -> NSView {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let titleLabel = NSTextField(labelWithString: snapshot.name)
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let kindLabel = NSTextField(labelWithString: snapshot.kind)
        kindLabel.font = NSFont.systemFont(ofSize: 12)
        kindLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [titleLabel, kindLabel])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let headerStack = NSStackView(views: [iconView, titleStack])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12

        var rows = [
            makeRow(label: "Host", value: snapshot.host),
            makeRow(label: "Path", value: snapshot.path),
            makeRow(label: "Size", value: snapshot.size),
            makeRow(label: "Modified", value: snapshot.modified),
            makeRow(label: "Hidden", value: snapshot.hidden),
            makeRow(label: "Readable", value: snapshot.readable),
        ]
        if let symlinkTarget = snapshot.symlinkTarget {
            rows.append(makeRow(label: "Target", value: symlinkTarget))
        }

        let detailsStack = NSStackView(views: rows)
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 8

        content.addSubview(headerStack)
        content.addSubview(detailsStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            headerStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            headerStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            detailsStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 20),
            detailsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            detailsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            detailsStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])

        return content
    }

    private func makeRow(label: String, value: String) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right

        let valueField = NSTextField(labelWithString: value)
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = NSFont.systemFont(ofSize: 12)
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.maximumNumberOfLines = 2
        valueField.allowsExpansionToolTips = true

        let row = NSStackView(views: [labelField, valueField])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10

        NSLayoutConstraint.activate([
            labelField.widthAnchor.constraint(equalToConstant: 70),
            valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])

        return row
    }
}
