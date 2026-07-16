import DetoursProcess
import XCTest

final class DetoursProcessTargetTests: XCTestCase {
    func testModuleIsAvailable() {
        _ = DetoursProcessModule.self
    }
}
