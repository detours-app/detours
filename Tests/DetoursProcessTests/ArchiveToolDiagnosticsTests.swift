import XCTest
@testable import DetoursProcess

final class ArchiveToolDiagnosticsTests: XCTestCase {
    func testFirstUnsafeMemberPathFlagsEscapingEntries() {
        XCTAssertNil(ArchiveToolDiagnostics.firstUnsafeMemberPath(["a.txt", "dir/", "dir/b.txt", ""]))
        XCTAssertEqual(ArchiveToolDiagnostics.firstUnsafeMemberPath(["../evil.txt"]), "../evil.txt")
        XCTAssertEqual(ArchiveToolDiagnostics.firstUnsafeMemberPath(["/etc/passwd"]), "/etc/passwd")
        XCTAssertEqual(ArchiveToolDiagnostics.firstUnsafeMemberPath(["dir/../../evil"]), "dir/../../evil")
        XCTAssertEqual(ArchiveToolDiagnostics.firstUnsafeMemberPath(["..\\evil"]), "..\\evil")
    }

    func testSevenZipListingMemberPathsHonoursSeparator() {
        let withHeader = """
        Path = archive.7z
        Type = 7z
        ----------
        Path = safe.txt
        Size = 4
        Path = dir/nested.txt
        """
        XCTAssertEqual(
            ArchiveToolDiagnostics.sevenZipListingMemberPaths(withHeader, requireSeparator: true),
            ["safe.txt", "dir/nested.txt"]
        )

        let bareListing = """
        Path = safe.txt
        Size = 4
        Path = ../evil.txt
        """
        XCTAssertEqual(
            ArchiveToolDiagnostics.sevenZipListingMemberPaths(bareListing, requireSeparator: false),
            ["safe.txt", "../evil.txt"]
        )
    }

    func testZipPasswordFailureClassification() {
        XCTAssertTrue(ArchiveToolDiagnostics.isZipPasswordFailure(message: "", status: 82))
        XCTAssertTrue(ArchiveToolDiagnostics.isZipPasswordFailure(message: "incorrect password", status: 1))
        XCTAssertTrue(ArchiveToolDiagnostics.isZipPasswordFailure(message: "password incorrect--reenter:", status: 1))
        XCTAssertTrue(ArchiveToolDiagnostics.isZipPasswordFailure(message: "no password was provided", status: 2))
        XCTAssertTrue(ArchiveToolDiagnostics.isZipPasswordFailure(message: "skipping: secret.txt encrypted", status: 1))
        XCTAssertFalse(ArchiveToolDiagnostics.isZipPasswordFailure(message: "central directory corrupt", status: 1))
        XCTAssertFalse(ArchiveToolDiagnostics.isZipPasswordFailure(message: "disk full", status: 3))
    }

    func testSevenZipPasswordMessageClassification() {
        XCTAssertTrue(ArchiveToolDiagnostics.isSevenZipPasswordMessage("ERROR: Wrong password : secret.txt"))
        XCTAssertTrue(ArchiveToolDiagnostics.isSevenZipPasswordMessage("Cannot open encrypted archive. Wrong password?"))
        XCTAssertTrue(ArchiveToolDiagnostics.isSevenZipPasswordMessage("ERROR: Data Error in encrypted file. Wrong password?"))
        XCTAssertFalse(ArchiveToolDiagnostics.isSevenZipPasswordMessage("ERROR: CRC Failed : file.bin"))
    }
}
