import Foundation
import XCTest
@testable import Detours

final class DetoursPreviewKindTests: XCTestCase {
    func testMarkdownExtensionsClassifyAsMarkdown() {
        for name in ["README.md", "guide.markdown", "notes.mdown"] {
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: URL(fileURLWithPath: name), sampleData: Data("# Title".utf8)),
                .markdown(language: "markdown")
            )
        }
    }

    func testCommonDeveloperExtensionsClassifyAsSourceOrConfig() {
        let samples: [(String, DetoursPreviewKind)] = [
            ("main.swift", .sourceCode(language: "swift")),
            ("app.js", .sourceCode(language: "javascript")),
            ("app.ts", .sourceCode(language: "typescript")),
            ("tool.py", .sourceCode(language: "python")),
            ("package.json", .configuration(language: "json")),
            ("config.yaml", .configuration(language: "yaml")),
            ("settings.toml", .configuration(language: "toml")),
            ("view.xml", .sourceCode(language: "xml")),
            ("script.sh", .sourceCode(language: "bash")),
            ("style.css", .sourceCode(language: "css")),
            ("index.html", .sourceCode(language: "xml")),
            ("query.sql", .sourceCode(language: "sql")),
            (".env", .configuration(language: "ini")),
            (".gitignore", .configuration(language: "plaintext"))
        ]

        for (name, expected) in samples {
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: URL(fileURLWithPath: name), sampleData: Data("text".utf8)),
                expected,
                name
            )
        }
    }

    func testBinarySniffingRejectsBinaryData() {
        let binary = Data([0x23, 0x21, 0x00, 0xFF, 0xD8])
        XCTAssertEqual(
            DetoursPreviewKind.classify(url: URL(fileURLWithPath: "maybe.txt"), sampleData: binary),
            .unsupported
        )
    }

    func testExtensionlessUtf8TextClassifiesAsPlainText() {
        XCTAssertEqual(
            DetoursPreviewKind.classify(url: URL(fileURLWithPath: "LICENSE"), sampleData: Data("plain text\n".utf8)),
            .plainText(language: "plaintext")
        )
    }
}
