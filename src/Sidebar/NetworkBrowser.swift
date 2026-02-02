import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "com.detours", category: "network-browser")

// MARK: - Network Protocol

enum NetworkProtocol: String, Codable, Equatable {
    case smb
    case nfs

    var urlScheme: String {
        switch self {
        case .smb: return "smb"
        case .nfs: return "nfs"
        }
    }

    var bonjourType: String {
        switch self {
        case .smb: return "_smb._tcp"
        case .nfs: return "_nfs._tcp"
        }
    }

    var displayName: String {
        rawValue.uppercased()
    }
}

// MARK: - Network Server

struct NetworkServer: Equatable, Hashable {
    let name: String
    let host: String
    let port: Int
    let `protocol`: NetworkProtocol

    var url: URL? {
        var components = URLComponents()
        components.scheme = `protocol`.urlScheme
        components.host = host
        if port != defaultPort {
            components.port = port
        }
        return components.url
    }

    private var defaultPort: Int {
        switch `protocol` {
        case .smb: return 445
        case .nfs: return 2049
        }
    }

    static func == (lhs: NetworkServer, rhs: NetworkServer) -> Bool {
        lhs.host == rhs.host && lhs.protocol == rhs.protocol
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(`protocol`)
    }
}

// MARK: - Network Browser

@MainActor
final class NetworkBrowser {
    static let shared = NetworkBrowser()

    static let serversDidChange = Notification.Name("NetworkBrowser.serversDidChange")

    private(set) var discoveredServers: [NetworkServer] = []

    /// Servers that were discovered but have gone offline (Bonjour removed them)
    /// while they still have mounted volumes. Keyed by host (lowercase).
    private(set) var offlineServers: Set<String> = []

    private var smbBrowser: NWBrowser?
    private var nfsBrowser: NWBrowser?

    private var pendingServers: Set<NetworkServer> = []

    private init() {
        start()
    }

    deinit {
        smbBrowser?.cancel()
        nfsBrowser?.cancel()
    }

    // MARK: - Lifecycle

    func start() {
        startBrowser(for: .smb)
        startBrowser(for: .nfs)
        logger.info("Network browser started")
    }

    func stop() {
        smbBrowser?.cancel()
        nfsBrowser?.cancel()
        smbBrowser = nil
        nfsBrowser = nil
        logger.info("Network browser stopped")
    }

    func refresh() {
        stop()
        pendingServers.removeAll()
        discoveredServers.removeAll()
        offlineServers.removeAll()
        notifyChange()
        start()
    }

    /// Check if a server (by host) is offline (Bonjour lost it but has mounted volumes)
    func isServerOffline(host: String) -> Bool {
        offlineServers.contains(host.lowercased())
    }

    /// Called when volumes change - clean up offline servers that no longer have volumes
    func refreshOfflineServers() {
        let currentVolumes = VolumeMonitor.shared.volumes
        var hostsWithVolumes: Set<String> = []
        for volume in currentVolumes {
            if let host = volume.serverHost?.lowercased() {
                hostsWithVolumes.insert(host)
            }
        }
        // Remove offline servers that no longer have volumes
        offlineServers = offlineServers.intersection(hostsWithVolumes)
    }

    // MARK: - Browser Setup

    private func startBrowser(for networkProtocol: NetworkProtocol) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: networkProtocol.bonjourType, domain: "local.")
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleStateUpdate(state, protocol: networkProtocol)
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleResultsChanged(results, changes: changes, protocol: networkProtocol)
            }
        }

        browser.start(queue: .main)

        switch networkProtocol {
        case .smb:
            smbBrowser = browser
        case .nfs:
            nfsBrowser = browser
        }
    }

    private func handleStateUpdate(_ state: NWBrowser.State, protocol networkProtocol: NetworkProtocol) {
        switch state {
        case .ready:
            logger.debug("\(networkProtocol.displayName) browser ready")
        case .failed(let error):
            logger.error("\(networkProtocol.displayName) browser failed: \(error.localizedDescription)")
        case .cancelled:
            logger.debug("\(networkProtocol.displayName) browser cancelled")
        default:
            break
        }
    }

    private func handleResultsChanged(
        _ results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        protocol networkProtocol: NetworkProtocol
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                if let server = parseResult(result, protocol: networkProtocol) {
                    pendingServers.insert(server)
                    // Server came back online - remove from offline set
                    offlineServers.remove(server.host.lowercased())
                    logger.info("Discovered \(networkProtocol.displayName) server: \(server.name)")
                }

            case .removed(let result):
                if let server = parseResult(result, protocol: networkProtocol) {
                    pendingServers.remove(server)
                    // Check if this server has mounted volumes - if so, mark as offline
                    let serverHost = server.host.lowercased()
                    let hasVolumes = VolumeMonitor.shared.volumes.contains { volume in
                        volume.serverHost?.lowercased() == serverHost
                    }
                    if hasVolumes {
                        offlineServers.insert(serverHost)
                        logger.info("Server \(server.name) went offline but has mounted volumes")
                    } else {
                        logger.info("Lost \(networkProtocol.displayName) server: \(server.name)")
                    }
                }

            case .changed(old: _, new: let newResult, flags: _):
                if let server = parseResult(newResult, protocol: networkProtocol) {
                    pendingServers.update(with: server)
                }

            case .identical:
                break

            @unknown default:
                break
            }
        }

        updateDiscoveredServers()
    }

    private func parseResult(_ result: NWBrowser.Result, protocol networkProtocol: NetworkProtocol) -> NetworkServer? {
        guard case .service(let name, _, _, _) = result.endpoint else {
            return nil
        }

        // Use the service name as the display name
        // Host will be resolved when mounting
        return NetworkServer(
            name: name,
            host: name,
            port: networkProtocol == .smb ? 445 : 2049,
            protocol: networkProtocol
        )
    }

    private func updateDiscoveredServers() {
        // Sort by name, limit to 20
        let sorted = pendingServers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let limited = Array(sorted.prefix(20))

        if limited != discoveredServers {
            discoveredServers = limited
            notifyChange()
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.serversDidChange, object: nil)
    }
}
