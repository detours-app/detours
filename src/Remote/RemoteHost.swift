import CryptoKit
import Foundation

struct RemoteHost: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var sshTarget: String
    var knownHostKeyFingerprint: String?
    var lastConnected: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        sshTarget: String,
        knownHostKeyFingerprint: String? = nil,
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sshTarget = sshTarget
        self.knownHostKeyFingerprint = knownHostKeyFingerprint
        self.lastConnected = lastConnected
    }

    var cacheDirectoryName: String {
        Self.cacheDirectoryName(hostID: id, sshTarget: sshTarget)
    }

    static func cacheDirectoryName(hostID: UUID, sshTarget: String) -> String {
        let digest = SHA256.hash(data: Data(sshTarget.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "remote-\(hostID.uuidString.lowercased())-\(digest)"
    }
}
