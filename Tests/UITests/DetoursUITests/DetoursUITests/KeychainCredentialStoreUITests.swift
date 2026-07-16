import XCTest

final class KeychainCredentialStoreUITests: BaseUITest {
    private struct LifecycleResult: Decodable {
        let success: Bool
        let failure: String?
    }

    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_KEYCHAIN_LIFECYCLE"] = "1"
    }

    func testSignedAppSaveRetrieveIsolationAndDelete() throws {
        let resultURL = uiTestRootURL.appendingPathComponent(".detours-keychain-lifecycle-result.json")
        expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: resultURL.path) },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 5)

        let result = try JSONDecoder().decode(LifecycleResult.self, from: Data(contentsOf: resultURL))
        XCTAssertTrue(result.success, result.failure ?? "Signed app Keychain lifecycle failed")
    }
}
