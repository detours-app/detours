import AppKit
import os.log
@preconcurrency import Quartz

// MARK: - Loading & Error States

extension FileListViewController {
    func showLoadingIndicator() {
        hideErrorOverlay()
        guard !suppressLoadingSpinner else { return }
        guard loadingSpinner == nil else { return }

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.sizeToFit()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimation(nil)
        loadingSpinner = spinner
    }

    func hideLoadingIndicator() {
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.removeFromSuperview()
        loadingSpinner = nil
    }

    func showErrorOverlay(for error: DirectoryLoadError) {
        hideErrorOverlay()

        let theme = ThemeManager.shared.currentTheme

        let messageText: String
        let symbolName: String
        let showRetry: Bool
        let showGoUp: Bool

        switch error {
        case .timeout:
            messageText = "Connection timed out"
            symbolName = "clock.badge.exclamationmark"
            showRetry = true
            showGoUp = false
        case .accessDenied:
            messageText = "Access denied"
            symbolName = "lock"
            showRetry = false
            showGoUp = true
        case .notFound:
            messageText = "Folder not found"
            symbolName = "questionmark.folder"
            showRetry = false
            showGoUp = true
        case .disconnected:
            messageText = "Volume disconnected"
            symbolName = "externaldrive.badge.xmark"
            showRetry = true
            showGoUp = true
        case .cancelled:
            return
        case .other(let desc):
            messageText = desc
            symbolName = "exclamationmark.triangle"
            showRetry = true
            showGoUp = false
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // Opaque fill so the error cleanly covers the list area; without it the overlay is
        // transparent and stale rows show through behind the message, which looks broken.
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.background.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        // SF Symbol icon
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: messageText)?
            .withSymbolConfiguration(symbolConfig) {
            let imageView = NSImageView(image: symbolImage)
            imageView.contentTintColor = theme.textSecondary
            stack.addArrangedSubview(imageView)
            stack.setCustomSpacing(8, after: imageView)
        }

        // Message
        let label = NSTextField(labelWithString: messageText)
        label.font = theme.uiFont(size: 13)
        label.textColor = theme.textSecondary
        label.alignment = .center
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(12, after: label)

        // Button row
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12

        if showGoUp {
            let goUpButton = NSButton(title: "Go to Parent Folder", target: self, action: #selector(goToNearestParent))
            goUpButton.bezelStyle = .push
            goUpButton.controlSize = .large
            if let keyEquivalent = goUpButton.cell as? NSButtonCell {
                keyEquivalent.backgroundColor = theme.accent
            }
            goUpButton.keyEquivalent = "\r"
            buttonStack.addArrangedSubview(goUpButton)
        }

        if showRetry {
            let retryButton = NSButton(title: "Retry", target: self, action: #selector(retryLoad))
            retryButton.bezelStyle = .push
            retryButton.controlSize = .large
            buttonStack.addArrangedSubview(retryButton)
        }

        if !buttonStack.arrangedSubviews.isEmpty {
            stack.addArrangedSubview(buttonStack)
        }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])

        view.addSubview(container, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scrollView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])

        errorOverlay = container
    }

    func hideErrorOverlay() {
        errorOverlay?.removeFromSuperview()
        errorOverlay = nil
    }

    @objc private func retryLoad() {
        retryCurrentLoad()
    }

    private func retryCurrentLoad() {
        if let currentRemoteLocation, let currentRemoteProvider {
            hideErrorOverlay()
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: true)
            return
        }
        guard let currentDirectory else { return }
        hideErrorOverlay()
        loadDirectory(currentDirectory, preserveExpansion: true)
    }

    #if DEBUG
    func retryCurrentLoadForTesting() {
        retryCurrentLoad()
    }
    #endif

    @objc private func goToNearestParent() {
        guard let currentDirectory else { return }
        hideErrorOverlay()

        var candidate = currentDirectory.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }

        navigationDelegate?.fileListDidRequestNavigation(to: candidate)
    }
}
