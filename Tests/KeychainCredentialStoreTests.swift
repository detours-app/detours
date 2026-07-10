import XCTest
@testable import Detours

@MainActor
final class KeychainCredentialStoreTests: XCTestCase {
    func testSaveHasAndDeleteAreIsolatedByAccount() throws {
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

        try store.delete(server: account)

        XCTAssertFalse(store.hasCredential(server: account))
        XCTAssertFalse(store.hasCredential(server: otherAccount))
    }
}
