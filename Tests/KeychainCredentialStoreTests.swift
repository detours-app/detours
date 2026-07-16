import Security
import XCTest
@testable import Detours

@MainActor
final class KeychainCredentialStoreTests: XCTestCase {
    func testRealKeychainSaveRetrieveAccountIsolationAndDelete() async throws {
        let store = KeychainCredentialStore(
            service: "com.detours.tests.\(UUID().uuidString)",
            accessControlFlags: []
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
        let credential = try await store.retrieve(server: account)
        XCTAssertEqual(credential?.username, "test-user")
        XCTAssertEqual(credential?.password, "test-password")

        try store.delete(server: account)

        XCTAssertFalse(store.hasCredential(server: account))
        let deletedCredential = try await store.retrieve(server: account)
        XCTAssertNil(deletedCredential)
    }
}
