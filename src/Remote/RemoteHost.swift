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
        "remote-\(shortCacheToken(for: hostID, length: 8))"
    }

    static func cacheDirectoryName(hostID: UUID, sshTarget: String) -> String {
        let digest = SHA256.hash(data: Data(sshTarget.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "remote-\(shortCacheToken(for: hostID, length: 8))-\(digest)"
    }

    static func cacheFileName(remotePath: String) -> String {
        let rawName = URL(fileURLWithPath: remotePath).lastPathComponent
        return sanitizedCacheComponent(rawName.isEmpty ? "remote-file" : rawName)
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

    private static func shortCacheToken(for id: UUID, length: Int) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(length)).lowercased()
    }
}
