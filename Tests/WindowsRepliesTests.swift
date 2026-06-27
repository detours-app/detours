import XCTest
@testable import Detours

final class WindowsRepliesTests: XCTestCase {
    func testParsesGetChildItemJson() throws {
        let json = """
        [
          {
            "Name": "Résumé.txt",
            "FullName": "C:\\\\Users\\\\sans\\\\Résumé.txt",
            "PSIsContainer": false,
            "Attributes": "Archive",
            "Length": 42,
            "LastWriteTimeUtc": "2026-06-25T12:34:56.000Z"
          },
          {
            "Name": ".hidden",
            "FullName": "C:\\\\Users\\\\sans\\\\.hidden",
            "PSIsContainer": true,
            "Attributes": "Directory, Hidden, ReparsePoint",
            "LastWriteTimeUtc": 1782390896000
          }
        ]
        """

        let entries = try WindowsReplyDecoder.decodeArrayOrSingle(
            WindowsDirectoryEntry.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Résumé.txt")
        XCTAssertEqual(entries[0].nativePath, "C:\\Users\\sans\\Résumé.txt")
        XCTAssertFalse(entries[0].isDirectory)
        XCTAssertEqual(entries[0].byteCount, 42)
        XCTAssertTrue(entries[1].isDirectory)
        XCTAssertTrue(entries[1].isHidden)
        XCTAssertTrue(entries[1].isReparsePoint)
    }

    func testParsesDriveListAndErrorEnvelope() throws {
        let driveJSON = """
        {"Name":"C","Root":"C:\\\\","Free":1000,"Used":2000}
        """
        let errorJSON = """
        {"Message":"Access denied","Category":"PermissionDenied","FullyQualifiedErrorId":"UnauthorizedAccess"}
        """

        let drives = try WindowsReplyDecoder.decodeArrayOrSingle(
            WindowsDriveEntry.self,
            from: Data(driveJSON.utf8)
        )
        let error = try JSONDecoder.detoursWindows.decode(WindowsErrorEnvelope.self, from: Data(errorJSON.utf8))

        let expectedDrive = try WindowsDriveEntryForTest(
            name: "C",
            nativeRoot: "C:\\",
            freeBytes: 1000,
            usedBytes: 2000
        ).entry
        XCTAssertEqual(drives, [expectedDrive])
        XCTAssertEqual(error.message, "Access denied")
        XCTAssertEqual(error.category, "PermissionDenied")
        XCTAssertEqual(error.fullyQualifiedErrorID, "UnauthorizedAccess")
    }

    func testDecodeArrayOrSingleRejectsMalformedNonNull() throws {
        // The exact literal `null` (with optional surrounding whitespace) is the empty result.
        XCTAssertTrue(try WindowsReplyDecoder.decodeArrayOrSingle(
            WindowsErrorEnvelope.self, from: Data("null".utf8)).isEmpty)
        XCTAssertTrue(try WindowsReplyDecoder.decodeArrayOrSingle(
            WindowsErrorEnvelope.self, from: Data("  null\n".utf8)).isEmpty)

        // Any other `n`-prefixed or non-array/non-object payload must surface a decode error.
        XCTAssertThrowsError(try WindowsReplyDecoder.decodeArrayOrSingle(
            WindowsErrorEnvelope.self, from: Data("nan".utf8)))
        XCTAssertThrowsError(try WindowsReplyDecoder.decodeArrayOrSingle(
            WindowsErrorEnvelope.self, from: Data("nul".utf8)))
        XCTAssertThrowsError(try WindowsReplyDecoder.decodeArrayOrSingle(
            WindowsErrorEnvelope.self, from: Data("123".utf8)))
    }

    func testGitStatusDecodesOctalEscapedNames() {
        // The decode runs host-side in PowerShell; assert the parser wires git's
        // octal-escape decoding (\NNN bytes -> UTF-8) into the status path.
        let script = WindowsFindScripts.gitStatus
        XCTAssertTrue(script.contains("function Convert-GitQuotedName"))
        XCTAssertTrue(script.contains("[Convert]::ToByte($inner.Substring($i + 1, 3), 8)"))
        XCTAssertTrue(script.contains("[System.Text.Encoding]::UTF8.GetString($bytes.ToArray())"))
        XCTAssertTrue(script.contains("$fileName = Convert-GitQuotedName -Name $fileName"))
    }
}

private struct WindowsDriveEntryForTest {
    let entry: WindowsDriveEntry

    init(name: String, nativeRoot: String, freeBytes: Int64?, usedBytes: Int64?) throws {
        let json = """
        {"Name":"\(name)","Root":"\(nativeRoot.replacingOccurrences(of: "\\", with: "\\\\"))","Free":\(freeBytes ?? 0),"Used":\(usedBytes ?? 0)}
        """
        entry = try JSONDecoder.detoursWindows.decode(WindowsDriveEntry.self, from: Data(json.utf8))
    }
}
