import XCTest
import Security
@testable import Detours

@MainActor
final class KeychainCredentialStoreTests: XCTestCase {
    private final class FakeKeychain {
        private struct Key: Hashable {
            let service: String
            let account: String
        }

        private var items: Set<Key> = []

        func add(_ query: CFDictionary) -> OSStatus {
            guard let key = key(from: query) else { return errSecParam }
            guard items.insert(key).inserted else { return errSecDuplicateItem }
            return errSecSuccess
        }

        func delete(_ query: CFDictionary) -> OSStatus {
            guard let key = key(from: query) else { return errSecParam }
            return items.remove(key) == nil ? errSecItemNotFound : errSecSuccess
        }

        func copyStatus(_ query: CFDictionary) -> OSStatus {
            guard let key = key(from: query) else { return errSecParam }
            return items.contains(key) ? errSecSuccess : errSecItemNotFound
        }

        private func key(from query: CFDictionary) -> Key? {
            let attributes = query as NSDictionary
            guard let service = attributes[kSecAttrService] as? String,
                  let account = attributes[kSecAttrAccount] as? String else {
                return nil
            }
            return Key(service: service, account: account)
        }
    }

    func testSaveHasAndDeleteAreIsolatedByAccount() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(
            service: "com.detours.tests.\(UUID().uuidString)",
            accessControlFlags: [],
            addItem: keychain.add,
            deleteItem: keychain.delete,
            copyItemStatus: keychain.copyStatus
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
