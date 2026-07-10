import XCTest
@testable import Detours
@testable import detours_server

/// The app and the remote helper each carry their own copy of git's C-quoting decoder, because the
/// helper ships as a standalone binary. These tests fail the moment the two disagree.
final class GitPorcelainUnquoteTests: XCTestCase {
    /// (C-quoted body as git emits it between the quotes, expected decoded filename)
    private let cases: [(quoted: String, decoded: String)] = [
        ("plain.txt", "plain.txt"),
        ("caf\\303\\251.txt", "café.txt"),
        ("\\303\\244\\303\\266\\303\\274.md", "äöü.md"),
        ("emoji \\360\\237\\223\\201.txt", "emoji 📁.txt"),
        ("say \\\"hi\\\".txt", "say \"hi\".txt"),
        ("back\\\\slash.txt", "back\\slash.txt"),
        ("tab\\there.txt", "tab\there.txt"),
        ("new\\nline.txt", "new\nline.txt"),
        ("carriage\\rreturn.txt", "carriage\rreturn.txt"),
        ("dir/nested caf\\303\\251.swift", "dir/nested café.swift")
    ]

    func testClientDecodesGitCQuoting() {
        for testCase in cases {
            XCTAssertEqual(
                GitStatusProvider.unquoteCQuoted(testCase.quoted),
                testCase.decoded,
                "client failed to decode \(testCase.quoted)"
            )
        }
    }

    func testServerDecodesGitCQuoting() {
        for testCase in cases {
            XCTAssertEqual(
                GitOperations.unquoteCQuoted(testCase.quoted),
                testCase.decoded,
                "server failed to decode \(testCase.quoted)"
            )
        }
    }

    func testClientAndServerDecodersAgree() {
        for testCase in cases {
            XCTAssertEqual(
                GitStatusProvider.unquoteCQuoted(testCase.quoted),
                GitOperations.unquoteCQuoted(testCase.quoted),
                "client and server disagree on \(testCase.quoted)"
            )
        }
    }

    func testTrailingBackslashIsPreservedRatherThanDropped() {
        XCTAssertEqual(GitStatusProvider.unquoteCQuoted("trailing\\"), "trailing\\")
        XCTAssertEqual(GitOperations.unquoteCQuoted("trailing\\"), "trailing\\")
    }
}
