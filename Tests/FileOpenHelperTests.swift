import XCTest
@testable import Detours

@MainActor
final class FileOpenHelperTests: XCTestCase {

    // MARK: - isDiskImage Tests

    func testIsDiskImageDMG() {
        let url = URL(fileURLWithPath: "/tmp/test.dmg")
        XCTAssertTrue(FileOpenHelper.isDiskImage(url))
    }

    func testIsDiskImageDMGUppercase() {
        let url = URL(fileURLWithPath: "/tmp/test.DMG")
        XCTAssertTrue(FileOpenHelper.isDiskImage(url))
    }

    func testIsDiskImageISO() {
        let url = URL(fileURLWithPath: "/tmp/test.iso")
        XCTAssertTrue(FileOpenHelper.isDiskImage(url))
    }

    func testIsDiskImageSparsebundle() {
        let url = URL(fileURLWithPath: "/tmp/test.sparsebundle")
        XCTAssertTrue(FileOpenHelper.isDiskImage(url))
    }

    func testIsDiskImageSparseimage() {
        let url = URL(fileURLWithPath: "/tmp/test.sparseimage")
        XCTAssertTrue(FileOpenHelper.isDiskImage(url))
    }

    func testIsDiskImageMixedCase() {
        let url = URL(fileURLWithPath: "/tmp/test.SpArSeImAgE")
        XCTAssertTrue(FileOpenHelper.isDiskImage(url))
    }

    func testIsNotDiskImageTxt() {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        XCTAssertFalse(FileOpenHelper.isDiskImage(url))
    }

    func testIsNotDiskImageApp() {
        let url = URL(fileURLWithPath: "/Applications/Safari.app")
        XCTAssertFalse(FileOpenHelper.isDiskImage(url))
    }

    func testIsNotDiskImagePDF() {
        let url = URL(fileURLWithPath: "/tmp/document.pdf")
        XCTAssertFalse(FileOpenHelper.isDiskImage(url))
    }

    func testIsNotDiskImageNoExtension() {
        let url = URL(fileURLWithPath: "/tmp/noextension")
        XCTAssertFalse(FileOpenHelper.isDiskImage(url))
    }

    func testIsNotDiskImageDmgInPath() {
        // Make sure we check the extension, not the path
        let url = URL(fileURLWithPath: "/tmp/dmg-folder/file.txt")
        XCTAssertFalse(FileOpenHelper.isDiskImage(url))
    }

    func testIsNotDiskImageZip() {
        let url = URL(fileURLWithPath: "/tmp/archive.zip")
        XCTAssertFalse(FileOpenHelper.isDiskImage(url))
    }

    // MARK: - diskImageExtensions Tests

    func testDiskImageExtensionsContainsExpectedTypes() {
        XCTAssertTrue(FileOpenHelper.diskImageExtensions.contains("dmg"))
        XCTAssertTrue(FileOpenHelper.diskImageExtensions.contains("iso"))
        XCTAssertTrue(FileOpenHelper.diskImageExtensions.contains("sparsebundle"))
        XCTAssertTrue(FileOpenHelper.diskImageExtensions.contains("sparseimage"))
    }

    func testDiskImageExtensionsCount() {
        // Guard against accidentally adding or removing extensions without updating tests
        XCTAssertEqual(FileOpenHelper.diskImageExtensions.count, 4)
    }
}
