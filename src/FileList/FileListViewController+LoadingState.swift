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

    func showRemoteRefreshError(
        directory: Location,
        error: any Error
    ) {
        remoteRefreshErrorBanner?.removeFromSuperview()
        failedRemoteRefreshDirectory = directory

        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        banner.setAccessibilityElement(true)
        banner.setAccessibilityRole(.group)
        banner.setAccessibilityIdentifier("remoteRefreshErrorBanner")

        let directoryName = directory.lastPathComponent.isEmpty
            ? directory.path
            : directory.lastPathComponent
        let message = "Could not refresh \"\(directoryName)\". \(error.localizedDescription)"
        banner.setAccessibilityLabel("Remote refresh failed. \(message)")

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ThemeManager.shared.currentTheme.uiFont(size: 12)
        label.textColor = ThemeManager.shared.currentTheme.textPrimary
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("remoteRefreshErrorLabel")

        let retryButton = NSButton(
            title: "Retry",
            target: self,
            action: #selector(retryRemoteRefresh)
        )
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.setAccessibilityIdentifier("remoteRefreshRetryButton")
        retryButton.setAccessibilityLabel("Retry remote refresh")

        banner.addSubview(label)
        banner.addSubview(retryButton)
        view.addSubview(banner, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 6),
            banner.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            retryButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            retryButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            retryButton.topAnchor.constraint(equalTo: banner.topAnchor, constant: 5),
            retryButton.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -5),
        ])
        remoteRefreshErrorBanner = banner

        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: "Remote refresh failed. Retry is available.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
        NSAccessibility.post(
            element: banner,
            notification: .announcementRequested,
            userInfo: userInfo
        )
    }

    func hideRemoteRefreshError(for directory: Location? = nil) {
        if let directory,
           failedRemoteRefreshDirectory != directory {
            return
        }
        remoteRefreshErrorBanner?.removeFromSuperview()
        remoteRefreshErrorBanner = nil
        failedRemoteRefreshDirectory = nil
    }

    @objc private func retryRemoteRefresh() {
        guard let directory = failedRemoteRefreshDirectory else { return }
        hideRemoteRefreshError()
        // The scheduler retained the failed intent's policy and completions;
        // the retry runs them after a successful apply.
        refreshScheduler.submitListingRefresh(directory: directory, cause: .retry)
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
        if let failedLocalRefreshDirectory {
            hideErrorOverlay()
            refreshScheduler.submitListingRefresh(
                directory: failedLocalRefreshDirectory,
                cause: .retry
            )
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
