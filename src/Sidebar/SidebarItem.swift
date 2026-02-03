import AppKit

// MARK: - Sidebar Section

enum SidebarSection: CaseIterable {
    case devices
    case network
    case favorites

    var title: String {
        switch self {
        case .devices: return "DEVICES"
        case .network: return "NETWORK"
        case .favorites: return "FAVORITES"
        }
    }
}

// MARK: - Sidebar Item

enum SidebarItem: Equatable {
    case section(SidebarSection)
    case device(VolumeInfo)
    case server(NetworkServer)
    case syntheticServer(SyntheticServer)
    case networkVolume(VolumeInfo)  // Volume displayed under a server in NETWORK section
    case favorite(URL)

    var url: URL? {
        switch self {
        case .section:
            return nil
        case .device(let volume):
            return volume.url
        case .server(let server):
            return server.url
        case .syntheticServer:
            return nil
        case .networkVolume(let volume):
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
        case (.server(let a), .server(let b)):
            return a == b
        case (.syntheticServer(let a), .syntheticServer(let b)):
            return a == b
        case (.networkVolume(let a), .networkVolume(let b)):
            return a.url == b.url
        case (.favorite(let a), .favorite(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Network Placeholder

enum NetworkPlaceholder {
    case noServersFound

    var text: String {
        switch self {
        case .noServersFound: return "No servers found"
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
    let isNetwork: Bool
    let serverHost: String?

    init(
        url: URL,
        name: String,
        icon: NSImage,
        capacity: Int64?,
        availableCapacity: Int64?,
        isEjectable: Bool,
        isNetwork: Bool = false,
        serverHost: String? = nil
    ) {
        self.url = url
        self.name = name
        self.icon = icon
        self.capacity = capacity
        self.availableCapacity = availableCapacity
        self.isEjectable = isEjectable
        self.isNetwork = isNetwork
        self.serverHost = serverHost
    }

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

    /// Check if this volume belongs to a server (case-insensitive host match)
    func matchesServer(_ server: NetworkServer) -> Bool {
        guard let host = serverHost else { return false }
        return host.caseInsensitiveCompare(server.host) == .orderedSame
    }
}

// MARK: - Synthetic Server

/// Represents a server derived from a mounted network volume that has no Bonjour discovery
struct SyntheticServer: Equatable, Hashable {
    let host: String

    var displayName: String {
        host
    }
}
