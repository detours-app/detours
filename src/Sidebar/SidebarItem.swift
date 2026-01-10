import AppKit

// MARK: - Sidebar Section

enum SidebarSection: CaseIterable {
    case devices
    case favorites

    var title: String {
        switch self {
        case .devices: return "Devices"
        case .favorites: return "Favorites"
        }
    }
}

// MARK: - Sidebar Item

enum SidebarItem: Equatable {
    case section(SidebarSection)
    case device(VolumeInfo)
    case favorite(URL)

    var url: URL? {
        switch self {
        case .section:
            return nil
        case .device(let volume):
            return volume.url
        case .favorite(let url):
            return url
        }
    }

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
        switch (lhs, rhs) {
        case (.section(let a), .section(let b)):
            return a == b
        case (.device(let a), .device(let b)):
            return a.url == b.url
        case (.favorite(let a), .favorite(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Volume Info

struct VolumeInfo {
    let url: URL
    let name: String
    let icon: NSImage
    let capacity: Int64?
    let availableCapacity: Int64?
    let isEjectable: Bool

    /// Format capacity as abbreviated string (e.g., "997G", "1.2T")
    var capacityString: String? {
        guard let available = availableCapacity else { return nil }
        return Self.formatBytes(available)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1000 && unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }

        if value >= 100 || unitIndex == 0 {
            return "\(Int(value))\(units[unitIndex])"
        } else if value >= 10 {
            return String(format: "%.0f%@", value, units[unitIndex])
        } else {
            return String(format: "%.1f%@", value, units[unitIndex])
        }
    }
}
