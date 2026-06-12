import Foundation

enum SSHAskPassPromptKind: Equatable, Sendable {
    case hostKey(fingerprint: String)
    case password
    case keyboardInteractive
    case privateKeyPassphrase
    case unknown
}

enum SSHAskPassBridgeError: Error, Equatable, Sendable {
    case hostKeyRejected(fingerprint: String)
    case sshAgentRequired(promptKind: SSHAskPassPromptKind)
}

struct SSHAskPassBridge: Sendable {
    typealias HostKeyConfirmation = (_ fingerprint: String, _ prompt: String) async throws -> Bool

    let askPassExecutableURL: URL?

    init(askPassExecutableURL: URL? = nil) {
        self.askPassExecutableURL = askPassExecutableURL
    }

    func environment() -> [String: String] {
        guard let askPassExecutableURL else { return [:] }
        return [
            "DISPLAY": "detours",
            "SSH_ASKPASS": askPassExecutableURL.path,
            "SSH_ASKPASS_REQUIRE": "force",
        ]
    }

    @MainActor
    func response(
        for prompt: String,
        confirmHostKey: HostKeyConfirmation
    ) async throws -> String {
        let kind = Self.classify(prompt)
        switch kind {
        case .hostKey(let fingerprint):
            guard try await confirmHostKey(fingerprint, prompt) else {
                throw SSHAskPassBridgeError.hostKeyRejected(fingerprint: fingerprint)
            }
            return "yes\n"
        case .password, .keyboardInteractive, .privateKeyPassphrase:
            throw SSHAskPassBridgeError.sshAgentRequired(promptKind: kind)
        case .unknown:
            throw SSHAskPassBridgeError.sshAgentRequired(promptKind: kind)
        }
    }

    static func classify(_ prompt: String) -> SSHAskPassPromptKind {
        let lowercased = prompt.lowercased()

        if let fingerprint = extractFingerprint(from: prompt),
           lowercased.contains("authenticity of host") || lowercased.contains("are you sure") {
            return .hostKey(fingerprint: fingerprint)
        }

        if lowercased.contains("passphrase for key") {
            return .privateKeyPassphrase
        }

        if lowercased.contains("keyboard-interactive") ||
            lowercased.contains("verification code") ||
            lowercased.contains("one-time password") {
            return .keyboardInteractive
        }

        if lowercased.contains("password") {
            return .password
        }

        return .unknown
    }

    private static func extractFingerprint(from prompt: String) -> String? {
        guard let range = prompt.range(of: "SHA256:") else { return nil }
        let suffix = prompt[range.lowerBound...]
        let fingerprint = suffix.prefix { character in
            character.isLetter || character.isNumber || character == ":" || character == "+" || character == "/" || character == "="
        }
        return fingerprint.isEmpty ? nil : String(fingerprint)
    }
}
