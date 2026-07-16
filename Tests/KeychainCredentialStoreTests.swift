import XCTest
import Security
@testable import Detours

@MainActor
final class KeychainCredentialStoreTests: XCTestCase {
    func testSaveHasAndDeleteAreIsolatedByAccount() throws {
        let keychainURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-tests-\(UUID().uuidString).keychain-db")
        let keychainPassword = "detours-test-keychain"
        var testKeychain: SecKeychain?
        let createStatus = keychainPassword.utf8CString.withUnsafeBufferPointer { password in
            SecKeychainCreate(
                keychainURL.path,
                UInt32(password.count - 1),
                password.baseAddress,
                false,
                nil,
                &testKeychain
            )
        }
        XCTAssertEqual(createStatus, errSecSuccess)
        let keychain = try XCTUnwrap(testKeychain)
        defer { SecKeychainDelete(keychain) }

        let store = KeychainCredentialStore(
            service: "com.detours.tests.\(UUID().uuidString)",
            accessControlFlags: [],
            keychain: keychain
        )
        let account = "detours-tests-\(UUID().uuidString)"
        let otherAccount = "detours-tests-\(UUID().uuidString)"
        defer {
            try? store.delete(server: account)
            try? store.delete(server: otherAccount)
        }

        XCTAssertFalse(store.hasCredential(server: account))
        XCTAssertFalse(store.hasCredential(server: otherAccount))

        try store.save(server: account, username: "test-user", password: "test-password")

        XCTAssertTrue(store.hasCredential(server: account))
        XCTAssertFalse(store.hasCredential(server: otherAccount))

        try store.delete(server: account)

        XCTAssertFalse(store.hasCredential(server: account))
        XCTAssertFalse(store.hasCredential(server: otherAccount))
    }
}
