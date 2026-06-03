import XCTest
@testable import Detours

@MainActor
final class SSHHostTrustTests: XCTestCase {
    func testHostKeyPromptRecordsFingerprint() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let defaults = try makeDefaults()
        let store = RemoteHostStore(defaults: defaults)
        let host = store.add(displayName: "Dev VM", sshTarget: "devtest")
        let trust = SSHHostTrust(knownHostsURL: temp.appendingPathComponent("known_hosts"))
        let bridge = SSHAskPassBridge()
        let prompt = """
        The authenticity of host 'devtest' can't be established.
        ED25519 key fingerprint is SHA256:abc123+/=.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        var callOrder: [String] = []

        try trust.prepareKnownHostsFile()
        let response = try await bridge.response(for: prompt) { fingerprint, _ in
            callOrder.append("confirm:\(fingerprint)")
            try trust.recordTrustedFingerprint(fingerprint, for: host.id, in: store)
            callOrder.append("record")
            return true
        }
        callOrder.append("list")
        let knownHostsContent = try String(contentsOf: trust.knownHostsURL, encoding: .utf8)

        XCTAssertEqual(response, "yes\n")
        XCTAssertEqual(store.host(id: host.id)?.knownHostKeyFingerprint, "SHA256:abc123+/=")
        XCTAssertTrue(knownHostsContent.contains("# detours-fingerprint \(host.id.uuidString) SHA256:abc123+/="))
        XCTAssertEqual(callOrder, ["confirm:SHA256:abc123+/=", "record", "list"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trust.knownHostsURL.path))
    }

    func testPassphrasePromptRejected() async throws {
        let bridge = SSHAskPassBridge()
        var confirmationCalled = false

        do {
            _ = try await bridge.response(for: "Enter passphrase for key '/Users/marco/.ssh/id_ed25519':") { _, _ in
                confirmationCalled = true
                return true
            }
            XCTFail("Expected passphrase prompt refusal")
        } catch let error as SSHAskPassBridgeError {
            XCTAssertEqual(error, .sshAgentRequired(promptKind: .privateKeyPassphrase))
            XCTAssertFalse(confirmationCalled)
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SSHHostTrustTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
