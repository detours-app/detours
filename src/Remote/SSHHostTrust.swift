import Foundation

struct SSHHostTrust: Sendable {
    let knownHostsURL: URL

    init(
        knownHostsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/known_hosts")
    ) {
        self.knownHostsURL = knownHostsURL
    }

    var sshArguments: [String] {
        [
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PubkeyAuthentication=yes",
            "-o", "NumberOfPasswordPrompts=0",
        ]
    }

    func prepareKnownHostsFile() throws {
        let directory = knownHostsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            FileManager.default.createFile(atPath: knownHostsURL.path, contents: nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
    }

    @MainActor
    func evaluateFingerprint(_ fingerprint: String, for hostID: UUID, in store: RemoteHostStore) -> SSHHostKeyEvaluation {
        guard let host = store.host(id: hostID),
              let known = host.knownHostKeyFingerprint,
              !known.isEmpty else {
            return .firstUse(fingerprint: fingerprint)
        }

        if known == fingerprint {
            return .trusted
        }

        return .changed(old: known, new: fingerprint)
    }

    @MainActor
    func recordTrustedFingerprint(_ fingerprint: String, for hostID: UUID, in store: RemoteHostStore) throws {
        try prepareKnownHostsFile()
        let marker = "# detours-fingerprint \(hostID.uuidString) \(fingerprint)\n"
        let handle = try FileHandle(forWritingTo: knownHostsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(marker.utf8))
        store.updateFingerprint(id: hostID, fingerprint: fingerprint)
    }
}

enum SSHHostKeyEvaluation: Equatable, Sendable {
    case trusted
    case firstUse(fingerprint: String)
    case changed(old: String, new: String)
}
