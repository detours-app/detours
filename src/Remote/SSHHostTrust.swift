import Foundation
import CryptoKit

struct SSHScannedHostKey: Equatable, Sendable {
    let hostPattern: String
    let keyType: String
    let publicKey: String
    let fingerprint: String

    var knownHostsLine: String {
        "\(hostPattern) \(keyType) \(publicKey)"
    }
}

enum SSHHostTrustError: Error, Equatable, LocalizedError {
    case targetResolutionFailed(String)
    case keyScanFailed(String)
    case noSupportedHostKey(String)
    case hostKeyRejected(String)
    case hostKeyChanged(old: String, new: String)

    var errorDescription: String? {
        switch self {
        case .targetResolutionFailed(let target):
            return "Could not resolve SSH target \"\(target)\"."
        case .keyScanFailed(let message):
            return message.isEmpty ? "Could not scan the SSH host key." : message
        case .noSupportedHostKey(let target):
            return "No supported SSH host key was found for \"\(target)\"."
        case .hostKeyRejected(let target):
            return "The SSH host key for \"\(target)\" was not trusted."
        case .hostKeyChanged(let old, let new):
            return "The SSH host key changed.\nKnown: \(old)\nNew: \(new)"
        }
    }
}

struct SSHHostTrust: Sendable {
    let knownHostsURL: URL

    init(
        knownHostsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
    ) {
        self.knownHostsURL = knownHostsURL
    }

    var sshArguments: [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PubkeyAuthentication=yes",
            "-o", "NumberOfPasswordPrompts=0",
            // Verify against the same file the app records fingerprints into, and fail closed on an
            // unknown or changed key instead of falling back to the user's global ssh defaults.
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
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
    func scanHostKey(for sshTarget: String) async throws -> SSHScannedHostKey {
        try await Task.detached(priority: .userInitiated) {
            let endpoint = try Self.resolvedEndpoint(for: sshTarget)
            let keyScan = try Self.run(
                executable: "/usr/bin/ssh-keyscan",
                arguments: ["-T", "8", "-p", endpoint.port, endpoint.hostname]
            )
            guard keyScan.status == 0 else {
                throw SSHHostTrustError.keyScanFailed(keyScan.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard let scannedKey = Self.preferredHostKey(from: keyScan.stdout) else {
                throw SSHHostTrustError.noSupportedHostKey(sshTarget)
            }
            return scannedKey
        }.value
    }

    func recordTrustedHostKey(_ hostKey: SSHScannedHostKey, hostID: UUID) throws {
        try prepareKnownHostsFile()
        let existing = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        let markerPrefix = "# detours-fingerprint \(hostID.uuidString) "
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            line == hostKey.knownHostsLine ||
                line.firstKnownHostsField == hostKey.hostPattern ||
                line.hasPrefix(markerPrefix)
        }
        lines.append(hostKey.knownHostsLine)
        lines.append("\(markerPrefix)\(hostKey.fingerprint)")
        try (lines.joined(separator: "\n") + "\n").write(to: knownHostsURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
    }

    @MainActor
    func recordTrustedHostKey(_ hostKey: SSHScannedHostKey, for hostID: UUID, in store: RemoteHostStore) throws {
        try recordTrustedHostKey(hostKey, hostID: hostID)
        store.updateFingerprint(id: hostID, fingerprint: hostKey.fingerprint)
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

    private static func resolvedEndpoint(for sshTarget: String) throws -> (hostname: String, port: String) {
        let resolved = try run(executable: "/usr/bin/ssh", arguments: ["-G", sshTarget])
        guard resolved.status == 0 else {
            throw SSHHostTrustError.targetResolutionFailed(sshTarget)
        }
        var hostname: String?
        var port = "22"
        for line in resolved.stdout.split(separator: "\n").map(String.init) {
            if line.hasPrefix("hostname ") {
                hostname = String(line.dropFirst("hostname ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("port ") {
                port = String(line.dropFirst("port ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let hostname, !hostname.isEmpty else {
            throw SSHHostTrustError.targetResolutionFailed(sshTarget)
        }
        return (hostname, port.isEmpty ? "22" : port)
    }

    private static func preferredHostKey(from keyScanOutput: String) -> SSHScannedHostKey? {
        let candidates = keyScanOutput
            .split(separator: "\n")
            .compactMap { scannedKey(from: String($0)) }
        let preference = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"]
        return candidates.min { lhs, rhs in
            let lhsIndex = preference.firstIndex(of: lhs.keyType) ?? preference.count
            let rhsIndex = preference.firstIndex(of: rhs.keyType) ?? preference.count
            return lhsIndex < rhsIndex
        }
    }

    private static func scannedKey(from line: String) -> SSHScannedHostKey? {
        guard !line.hasPrefix("#") else { return nil }
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count >= 3 else { return nil }
        let hostPattern = fields[0]
        let keyType = fields[1]
        let publicKey = fields[2]
        guard let keyData = Data(base64Encoded: publicKey) else { return nil }
        let digest = SHA256.hash(data: keyData)
        let fingerprint = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHScannedHostKey(
            hostPattern: hostPattern,
            keyType: keyType,
            publicKey: publicKey,
            fingerprint: "SHA256:\(fingerprint)"
        )
    }

    private static func run(executable: String, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

enum SSHHostKeyEvaluation: Equatable, Sendable {
    case trusted
    case firstUse(fingerprint: String)
    case changed(old: String, new: String)
}

private extension String {
    var firstKnownHostsField: String? {
        guard !hasPrefix("#") else { return nil }
        return split(separator: " ", maxSplits: 1).first.map(String.init)
    }
}
