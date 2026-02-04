@preconcurrency import CoreFoundation
import Foundation
import Security
import LocalAuthentication
import os.log

private let logger = Logger(subsystem: "com.detours", category: "keychain")

// MARK: - Keychain Error

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case userCancelled
    case accessDenied
    case itemNotFound
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save credentials: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")"
        case .retrieveFailed(let status):
            return "Failed to retrieve credentials: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")"
        case .deleteFailed(let status):
            return "Failed to delete credentials: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")"
        case .userCancelled:
            return "Authentication was cancelled."
        case .accessDenied:
            return "Access to credentials was denied."
        case .itemNotFound:
            return "No credentials found for this server."
        case .unexpectedData:
            return "Unexpected data format in keychain."
        }
    }
}

// MARK: - Keychain Credential Store

@MainActor
final class KeychainCredentialStore {
    static let shared = KeychainCredentialStore()

    private let service = "com.detours.network"

    private init() {}

    // MARK: - Save

    /// Save credentials for a server with user presence required for retrieval
    /// - Parameters:
    ///   - server: The server hostname
    ///   - username: The username
    ///   - password: The password
    func save(server: String, username: String, password: String) throws {
        // Delete any existing credential first
        try? delete(server: server)

        // Create access control requiring user presence (Touch ID / password)
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            if let error = accessError?.takeRetainedValue() {
                logger.error("Failed to create access control: \(error.localizedDescription)")
            }
            throw KeychainError.saveFailed(errSecParam)
        }

        // Encode credentials as JSON
        let credentials = ["username": username, "password": password]
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw KeychainError.saveFailed(errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Failed to save credentials for \(server): \(status)")
            throw KeychainError.saveFailed(status)
        }

        logger.info("Saved credentials for \(server)")
    }

    // MARK: - Retrieve

    /// Retrieve credentials for a server (will prompt for Touch ID / password)
    /// - Parameter server: The server hostname
    /// - Returns: Username and password if found, nil if no credentials stored
    func retrieve(server: String) async throws -> (username: String, password: String)? {
        // Check if credential exists first (without prompting)
        guard hasCredential(server: server) else {
            return nil
        }

        // Create LAContext for authentication prompt
        let context = LAContext()
        context.localizedReason = "Access credentials for \(server)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]

        let cfQuery = query as CFDictionary

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: AnyObject?
                let status = SecItemCopyMatching(cfQuery, &result)

                Task { @MainActor in
                    if status == errSecSuccess {
                        guard let data = result as? Data,
                              let credentials = try? JSONDecoder().decode([String: String].self, from: data),
                              let username = credentials["username"],
                              let password = credentials["password"] else {
                            continuation.resume(throwing: KeychainError.unexpectedData)
                            return
                        }
                        logger.info("Retrieved credentials for \(server)")
                        continuation.resume(returning: (username, password))
                    } else if status == errSecUserCanceled {
                        continuation.resume(throwing: KeychainError.userCancelled)
                    } else if status == errSecAuthFailed {
                        continuation.resume(throwing: KeychainError.accessDenied)
                    } else if status == errSecItemNotFound {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: KeychainError.retrieveFailed(status))
                    }
                }
            }
        }
    }

    // MARK: - Delete

    /// Delete stored credentials for a server
    func delete(server: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Failed to delete credentials for \(server): \(status)")
            throw KeychainError.deleteFailed(status)
        }

        logger.info("Deleted credentials for \(server)")
    }

    // MARK: - Check Existence

    /// Check if credentials exist for a server (without requiring authentication)
    func hasCredential(server: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // errSecInteractionNotAllowed means item exists but requires auth
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
