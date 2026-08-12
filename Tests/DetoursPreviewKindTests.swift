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

    func testHTMLExtensionsClassifyAsRenderedDocuments() {
        for name in ["index.html", "legacy.htm"] {
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: URL(fileURLWithPath: name), sampleData: Data("<h1>Title</h1>".utf8)),
                .htmlDocument(language: "xml")
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
            ("events.jsonl", .configuration(language: "json")),
            ("stream.ndjson", .configuration(language: "json")),
            ("config.yaml", .configuration(language: "yaml")),
            ("settings.toml", .configuration(language: "toml")),
            ("view.xml", .sourceCode(language: "xml")),
            ("script.sh", .sourceCode(language: "bash")),
            ("style.css", .sourceCode(language: "css")),
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

    func testLanguagesMacOSCannotTypeStillClassifyAsSource() {
        let samples: [(String, DetoursPreviewKind)] = [
            ("server.go", .sourceCode(language: "go")),
            ("lib.rs", .sourceCode(language: "rust")),
            ("Main.kt", .sourceCode(language: "kotlin")),
            ("Program.cs", .sourceCode(language: "csharp")),
            ("widget.dart", .sourceCode(language: "dart")),
            ("init.lua", .sourceCode(language: "lua")),
            ("main.tf", .sourceCode(language: "hcl")),
            ("schema.graphql", .sourceCode(language: "graphql")),
            ("App.vue", .sourceCode(language: "xml")),
            ("App.svelte", .sourceCode(language: "xml")),
            ("theme.scss", .sourceCode(language: "css")),
            ("theme.less", .sourceCode(language: "css"))
        ]

        for (name, expected) in samples {
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: URL(fileURLWithPath: name), sampleData: Data("text".utf8)),
                expected,
                name
            )
        }
    }

    func testRemainingCommonLanguagesClassifyAsSource() {
        let samples: [(String, DetoursPreviewKind)] = [
            ("engine.c", .sourceCode(language: "c")),
            ("engine.cpp", .sourceCode(language: "cpp")),
            ("AppDelegate.m", .sourceCode(language: "objectivec")),
            ("Service.java", .sourceCode(language: "java")),
            ("index.php", .sourceCode(language: "php")),
            ("model.rb", .sourceCode(language: "ruby")),
            ("report.pl", .sourceCode(language: "perl")),
            ("analysis.r", .sourceCode(language: "r")),
            ("api.proto", .sourceCode(language: "protobuf")),
            ("build.gradle", .sourceCode(language: "groovy")),
            ("Deploy.ps1", .sourceCode(language: "powershell")),
            ("app.ex", .sourceCode(language: "elixir")),
            ("Main.hs", .sourceCode(language: "haskell"))
        ]

        for (name, expected) in samples {
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: URL(fileURLWithPath: name), sampleData: Data("text".utf8)),
                expected,
                name
            )
        }
    }

    func testBuildFilesMatchTheirFamilyRatherThanOneSpelling() {
        let samples: [(String, DetoursPreviewKind)] = [
            ("Dockerfile", .configuration(language: "plaintext")),
            ("Dockerfile.dev", .configuration(language: "plaintext")),
            ("Makefile.local", .configuration(language: "plaintext")),
            (".env.production", .configuration(language: "ini")),
            ("Gemfile", .configuration(language: "ruby")),
            (".gitconfig", .configuration(language: "ini")),
            ("Package.resolved", .configuration(language: "json")),
            ("Detours.entitlements", .configuration(language: "xml"))
        ]

        for (name, expected) in samples {
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: URL(fileURLWithPath: name), sampleData: Data("text".utf8)),
                expected,
                name
            )
        }
    }

    func testVectorImagesStayWithTheImagePreviewInsteadOfBecomingMarkup() {
        XCTAssertEqual(
            DetoursPreviewKind.classify(
                url: URL(fileURLWithPath: "logo.svg"),
                sampleData: Data("<svg></svg>".utf8)
            ),
            .unsupported
        )
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

    func testDelimitedExtensionsClassifyAsTable() {
        let samples: [(String, Character)] = [("export.csv", ","), ("data.tsv", "\t"), ("data.tab", "\t")]
        for (name, delimiter) in samples {
            XCTAssertEqual(
                DetoursPreviewKind.classify(
                    url: URL(fileURLWithPath: name),
                    sampleData: Data("a,b\n1,2\n".utf8)
                ),
                .delimitedTable(delimiter: delimiter)
            )
        }
    }

    func testOfficeExtensionsClassifyAsDocumentAndSpreadsheet() {
        // A container of compressed parts always sniffs as binary, and these two must survive it.
        let container = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0xD8])

        XCTAssertEqual(
            DetoursPreviewKind.classify(url: URL(fileURLWithPath: "report.docx"), sampleData: container),
            .wordDocument
        )
        XCTAssertEqual(
            DetoursPreviewKind.classify(url: URL(fileURLWithPath: "budget.xlsx"), sampleData: container),
            .spreadsheet
        )
    }

    func testUnknownExtensionsFallBackToPlainTextWhenTheBytesAreText() {
        for name in ["scan.nmap", "scan.gnmap", "loot.unknown-tool-format"] {
            XCTAssertEqual(
                DetoursPreviewKind.classify(
                    url: URL(fileURLWithPath: name),
                    sampleData: Data("Nmap scan report for 10.0.0.1\n22/tcp open ssh\n".utf8)
                ),
                .plainText(language: "plaintext"),
                name
            )
        }
    }

    func testRenderedFormatsStayWithTheSystemPreviewDespiteReadingAsText() {
        for name in ["report.pdf", "logo.svg", "notes.rtf", "meeting.ics", "contact.vcf"] {
            XCTAssertEqual(
                DetoursPreviewKind.classify(
                    url: URL(fileURLWithPath: name),
                    sampleData: Data("%PDF-1.4 plain looking header".utf8)
                ),
                .unsupported,
                name
            )
        }
    }

    func testSecurityToolingExtensionsClassifyByTheirRealSyntax() {
        let samples: [(String, DetoursPreviewKind)] = [
            ("http-title.nse", .sourceCode(language: "lua")),
            ("internal.nessus", .sourceCode(language: "xml")),
            ("shell.jsp", .sourceCode(language: "xml")),
            ("upload.aspx", .sourceCode(language: "xml")),
            ("malware.yar", .sourceCode(language: "c")),
            ("Invoke-Recon.psm1", .sourceCode(language: "powershell")),
            ("session.har", .configuration(language: "json")),
            ("client.ovpn", .configuration(language: "ini")),
            ("dump.ldif", .configuration(language: "ini")),
            ("suricata.rules", .plainText(language: "plaintext")),
            ("rockyou.lst", .plainText(language: "plaintext")),
            ("ntlm.hash", .plainText(language: "plaintext")),
            ("server.pem", .plainText(language: "plaintext")),
            ("id_rsa.pub", .plainText(language: "plaintext")),
            ("sshd_config", .configuration(language: "ini")),
            ("authorized_keys", .configuration(language: "plaintext")),
            ("hosts", .configuration(language: "ini"))
        ]

        for (name, expected) in samples {
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: URL(fileURLWithPath: name), sampleData: Data("text".utf8)),
                expected,
                name
            )
        }
    }

    func testUTF16RegistryExportsAreTreatedAsTextRatherThanBinary() {
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: Array("Windows Registry Editor Version 5.00".utf16).flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        })

        XCTAssertEqual(
            DetoursPreviewKind.classify(url: URL(fileURLWithPath: "export.reg"), sampleData: data),
            .configuration(language: "ini")
        )
    }

    func testBinaryDataWithACSVExtensionIsRejected() {
        let binary = Data([0x23, 0x21, 0x00, 0xFF, 0xD8])
        XCTAssertEqual(
            DetoursPreviewKind.classify(url: URL(fileURLWithPath: "maybe.csv"), sampleData: binary),
            .unsupported
        )
    }
}
