import XCTest
@testable import Detours

final class WindowsArchiveScriptTests: XCTestCase {
    func testZipArchiveIncludesHiddenEntries() {
        let script = WindowsArchiveScripts.zipCreate

        XCTAssertTrue(script.hasPrefix("param($Arguments)"))
        XCTAssertTrue(script.contains("System.IO.Compression.ZipArchive"))
        XCTAssertTrue(script.contains("Get-ChildItem -LiteralPath $Item.FullName -Force"))
        XCTAssertTrue(script.contains("Get-RelativeArchiveName"))
        XCTAssertTrue(script.contains("Built-in ZIP cannot archive entries larger than 4 GiB"))
        XCTAssertFalse(script.contains("Compress-Archive"))
    }

    func testArchiveExtractRejectsEscapingEntries() {
        for script in [WindowsArchiveScripts.zipExtract, WindowsArchiveScripts.externalExtract] {
            XCTAssertTrue(script.contains("Assert-PathWithinDirectory"))
            XCTAssertTrue(script.contains("escapes the destination directory"))
        }
        // The built-in zip path validates each entry's destination before extracting it.
        XCTAssertTrue(WindowsArchiveScripts.zipExtract.contains("foreach ($entry in $zip.Entries)"))
    }
}
