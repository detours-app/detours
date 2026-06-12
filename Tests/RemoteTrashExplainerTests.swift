import XCTest
@testable import Detours

@MainActor
final class RemoteTrashExplainerTests: XCTestCase {
    func testShouldShowUntilDismissed() {
        let suiteName = "RemoteTrashExplainerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(RemoteTrashExplainer.shouldShow(defaults: defaults))

        RemoteTrashExplainer.markDismissed(defaults: defaults)

        XCTAssertFalse(RemoteTrashExplainer.shouldShow(defaults: defaults))
    }

    func testHelpMenuContainsRemoteTrashItem() {
        let target = AppDelegate()

        let item = makeRemoteTrashHelpMenuItem(target: target)

        XCTAssertEqual(item.title, "About Remote Trash")
        XCTAssertTrue(item.target === target)
        XCTAssertEqual(item.action, #selector(AppDelegate.showRemoteTrashInfo(_:)))
    }

}
