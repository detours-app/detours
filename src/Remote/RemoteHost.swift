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

    static func cacheDirectoryName(hostID: UUID) -> String {
        "remote-\(hostID.uuidString.lowercased())"
    }

    static func cacheDirectoryName(hostID: UUID, sshTarget: String) -> String {
        let digest = SHA256.hash(data: Data(sshTarget.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "remote-\(hostID.uuidString.lowercased())-\(digest)"
    }

    static func cacheFileName(remotePath: String) -> String {
        let digest = SHA256.hash(data: Data(remotePath.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let rawName = URL(fileURLWithPath: remotePath).lastPathComponent
        let sanitized = sanitizedCacheComponent(rawName.isEmpty ? "remote-file" : rawName)
        return "\(digest)-\(sanitized)"
    }

    private static func sanitizedCacheComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return collapsed.isEmpty ? "remote-file" : collapsed
    }
}
