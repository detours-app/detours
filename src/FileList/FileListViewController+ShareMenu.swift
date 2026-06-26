import AppKit
import UniformTypeIdentifiers

// MARK: - Share Menu Delegate

@MainActor
final class ShareMenuDelegate: NSObject, NSMenuDelegate {
    private weak var fileListViewController: FileListViewController?

    init(fileListViewController: FileListViewController) {
        self.fileListViewController = fileListViewController
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let fileListVC = fileListViewController else { return }
        let urls = fileListVC.selectedURLs
        guard !urls.isEmpty else {
            let noItems = NSMenuItem(title: "No files selected", action: nil, keyEquivalent: "")
            noItems.isEnabled = false
            menu.addItem(noItems)
            return
        }

        let services = SharingServiceHelper.services(for: urls)
        guard !services.isEmpty else {
            let noServices = NSMenuItem(title: "No sharing services available", action: nil, keyEquivalent: "")
            noServices.isEnabled = false
            menu.addItem(noServices)
            return
        }

        // Find AirDrop and put it first
        var airDropService: NSSharingService?
        var otherServices: [NSSharingService] = []
        for service in services {
            if service == NSSharingService(named: .sendViaAirDrop) {
                airDropService = service
            } else {
                otherServices.append(service)
            }
        }

        if let airDrop = airDropService {
            let item = makeMenuItem(for: airDrop, target: fileListVC)
            menu.addItem(item)
            if !otherServices.isEmpty {
                menu.addItem(NSMenuItem.separator())
            }
        }

        for service in otherServices {
            let item = makeMenuItem(for: service, target: fileListVC)
            menu.addItem(item)
        }
    }

    private func makeMenuItem(for service: NSSharingService, target: FileListViewController) -> NSMenuItem {
        let item = NSMenuItem(title: service.title, action: #selector(FileListViewController.shareViaService(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = service
        item.image = service.image
        item.image?.size = NSSize(width: 16, height: 16)
        return item
    }
}

// MARK: - Sharing Service Helper

/// Wraps the deprecated `sharingServices(forItems:)` call.
/// Apple recommends `NSSharingServicePicker.standardShareMenuItem` but that
/// doesn't allow custom ordering (AirDrop first with separator).
enum SharingServiceHelper {
    /// Returns sharing services for the given items.
    /// Uses dynamic dispatch to call the deprecated `sharingServices(forItems:)` —
    /// `NSSharingServicePicker.standardShareMenuItem` doesn't allow custom ordering
    /// (AirDrop first with separator), so we still need the old API.
    static func services(for items: [Any]) -> [NSSharingService] {
        let selector = NSSelectorFromString("sharingServicesForItems:")
        guard let result = NSSharingService.perform(selector, with: items) else {
            return []
        }
        return result.takeUnretainedValue() as? [NSSharingService] ?? []
    }
}
