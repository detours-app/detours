import XCTest
@testable import Detours

final class NetworkTests: XCTestCase {

    // MARK: - NetworkProtocol Tests

    func testNetworkProtocolURLSchemes() {
        // SMB scheme
        XCTAssertEqual(NetworkProtocol.smb.urlScheme, "smb")
        XCTAssertEqual(NetworkProtocol.smb.bonjourType, "_smb._tcp")
        XCTAssertEqual(NetworkProtocol.smb.displayName, "SMB")

        // NFS scheme
        XCTAssertEqual(NetworkProtocol.nfs.urlScheme, "nfs")
        XCTAssertEqual(NetworkProtocol.nfs.bonjourType, "_nfs._tcp")
        XCTAssertEqual(NetworkProtocol.nfs.displayName, "NFS")
    }

    // MARK: - NetworkServer Tests

    func testNetworkServerEquality() {
        let server1 = NetworkServer(name: "Server A", host: "192.168.1.100", port: 445, protocol: .smb)
        let server2 = NetworkServer(name: "Server B", host: "192.168.1.100", port: 445, protocol: .smb)
        let server3 = NetworkServer(name: "Server A", host: "192.168.1.101", port: 445, protocol: .smb)
        let server4 = NetworkServer(name: "Server A", host: "192.168.1.100", port: 2049, protocol: .nfs)

        // Same host and protocol = equal (name doesn't matter)
        XCTAssertEqual(server1, server2)

        // Different host = not equal
        XCTAssertNotEqual(server1, server3)

        // Different protocol = not equal
        XCTAssertNotEqual(server1, server4)
    }

    func testNetworkServerURL() {
        // SMB server with default port
        let smbServer = NetworkServer(name: "NAS", host: "nas.local", port: 445, protocol: .smb)
        XCTAssertEqual(smbServer.url?.absoluteString, "smb://nas.local")

        // SMB server with non-default port
        let smbCustomPort = NetworkServer(name: "NAS", host: "nas.local", port: 8445, protocol: .smb)
        XCTAssertEqual(smbCustomPort.url?.absoluteString, "smb://nas.local:8445")

        // NFS server with default port
        let nfsServer = NetworkServer(name: "NFS", host: "nfs.local", port: 2049, protocol: .nfs)
        XCTAssertEqual(nfsServer.url?.absoluteString, "nfs://nfs.local")

        // NFS server with non-default port
        let nfsCustomPort = NetworkServer(name: "NFS", host: "nfs.local", port: 3049, protocol: .nfs)
        XCTAssertEqual(nfsCustomPort.url?.absoluteString, "nfs://nfs.local:3049")
    }

    // MARK: - NetworkMountError Tests

    func testNetworkMountErrorDescriptions() {
        // Verify all error cases have user-friendly descriptions
        let errors: [NetworkMountError] = [
            .authenticationFailed,
            .serverUnreachable,
            .permissionDenied,
            .cancelled,
            .invalidURL,
            .mountFailed(99),
            .unknown("Test error"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }

        // Verify specific messages
        XCTAssertTrue(NetworkMountError.authenticationFailed.errorDescription!.contains("Authentication"))
        XCTAssertTrue(NetworkMountError.serverUnreachable.errorDescription!.contains("server"))
        XCTAssertTrue(NetworkMountError.permissionDenied.errorDescription!.contains("Permission"))
        XCTAssertTrue(NetworkMountError.cancelled.errorDescription!.contains("cancelled"))
        XCTAssertTrue(NetworkMountError.invalidURL.errorDescription!.contains("Invalid"))
        XCTAssertTrue(NetworkMountError.mountFailed(99).errorDescription!.contains("99"))
        XCTAssertTrue(NetworkMountError.unknown("Custom").errorDescription!.contains("Custom"))
    }

    // MARK: - ConnectToServerModel Tests

    func testConnectToServerURLValidation() {
        let model = ConnectToServerModel(recentServers: [])

        // Invalid: empty
        model.urlString = ""
        XCTAssertFalse(model.isValidURL)

        // Invalid: no scheme
        model.urlString = "nas.local/share"
        XCTAssertFalse(model.isValidURL)

        // Invalid: http scheme
        model.urlString = "http://nas.local"
        XCTAssertFalse(model.isValidURL)

        // Invalid: no host
        model.urlString = "smb:///share"
        XCTAssertFalse(model.isValidURL)

        // Valid: smb with host
        model.urlString = "smb://nas.local"
        XCTAssertTrue(model.isValidURL)

        // Valid: smb with host and share
        model.urlString = "smb://nas.local/share"
        XCTAssertTrue(model.isValidURL)

        // Valid: nfs with host
        model.urlString = "nfs://nfs.local"
        XCTAssertTrue(model.isValidURL)

        // Valid: nfs with export path
        model.urlString = "nfs://nfs.local/export/path"
        XCTAssertTrue(model.isValidURL)
    }

    // MARK: - Settings Tests

    @MainActor
    func testRecentServersMaxCount() {
        // Save original settings
        let originalServers = SettingsManager.shared.recentServers

        // Clear recent servers
        SettingsManager.shared.recentServers = []

        // Add 15 servers
        for i in 1...15 {
            let url = URL(string: "smb://server\(i).local/share")!
            SettingsManager.shared.addRecentServer(url)
        }

        // Should be capped at 10
        XCTAssertEqual(SettingsManager.shared.recentServers.count, 10)

        // Most recent should be first
        XCTAssertEqual(SettingsManager.shared.recentServers.first, "smb://server15.local/share")

        // Oldest (server6 through server10) should still be present, server1-5 dropped
        XCTAssertTrue(SettingsManager.shared.recentServers.contains("smb://server6.local/share"))
        XCTAssertFalse(SettingsManager.shared.recentServers.contains("smb://server5.local/share"))

        // Restore original settings
        SettingsManager.shared.recentServers = originalServers
    }

    @MainActor
    func testRecentServersPersistence() {
        // Save original settings
        let originalServers = SettingsManager.shared.recentServers

        // Add a test server
        let testURL = URL(string: "smb://test-persistence.local/share")!
        SettingsManager.shared.addRecentServer(testURL)

        // Verify it's there
        XCTAssertTrue(SettingsManager.shared.recentServers.contains(testURL.absoluteString))

        // Adding same URL again should move it to top, not duplicate
        let anotherURL = URL(string: "smb://another.local/share")!
        SettingsManager.shared.addRecentServer(anotherURL)
        SettingsManager.shared.addRecentServer(testURL)

        // testURL should be first (most recent)
        XCTAssertEqual(SettingsManager.shared.recentServers.first, testURL.absoluteString)

        // Should only appear once
        let count = SettingsManager.shared.recentServers.filter { $0 == testURL.absoluteString }.count
        XCTAssertEqual(count, 1)

        // Restore original settings
        SettingsManager.shared.recentServers = originalServers
    }
}
