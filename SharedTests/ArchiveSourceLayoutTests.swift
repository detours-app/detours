import XCTest
@testable import DetoursProcess

final class ArchiveSourceLayoutTests: XCTestCase {
    func testSelectionAcrossBranchesUsesCommonAncestorAndPreservesRelativePaths() {
        let layout = ArchiveSourceLayout(items: [
            URL(fileURLWithPath: "/tmp/root/Alpha/one.txt"),
            URL(fileURLWithPath: "/tmp/root/Beta/two.txt"),
        ])

        XCTAssertEqual(layout.workingDirectory.path, "/tmp/root")
        XCTAssertEqual(layout.relativePaths, ["Alpha/one.txt", "Beta/two.txt"])
    }

    func testLeadingDashFilenameRemainsARelativeOperand() {
        let layout = ArchiveSourceLayout(items: [
            URL(fileURLWithPath: "/tmp/root/-TT"),
            URL(fileURLWithPath: "/tmp/root/payload.txt"),
        ])

        XCTAssertEqual(layout.workingDirectory.path, "/tmp/root")
        XCTAssertEqual(layout.relativePaths, ["-TT", "payload.txt"])
    }
}
