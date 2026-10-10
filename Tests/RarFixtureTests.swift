import CryptoKit
import DetoursProcess
import Foundation
import XCTest

final class RarFixtureTests: XCTestCase {
    func testPinnedInputsMatchIndependentReferences() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("resources/fixtures/rar")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertFalse(manifest.files.isEmpty)
        for file in manifest.files {
            let bytes = try Data(contentsOf: root.appendingPathComponent(file.path))
            XCTAssertEqual(bytes.count, file.bytes, file.path)
            XCTAssertEqual(Self.digest(bytes), file.sha256, file.path)
        }
        for source in manifest.sources {
            XCTAssertEqual(source.commit.count, 40)
            XCTAssertTrue(manifest.files.contains { $0.path == source.licenseFile })
            XCTAssertFalse(try Data(contentsOf: root.appendingPathComponent(source.licenseFile)).isEmpty)
        }
        let fixture = try XCTUnwrap(manifest.archives.first { $0.id == "encrypted-multipart-rar4" })
        XCTAssertEqual(fixture.parts.count, 6)
        XCTAssertEqual(fixture.expected.count, 3)
        let tool = try XCTUnwrap(["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }, "Full free 7-Zip is required to qualify the encrypted multipart reference.")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("detours-rar-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: destination) } catch {
                XCTFail("Reference qualification cleanup failed: \(error)")
            }
        }
        let first = try XCTUnwrap(fixture.parts.first)
        let invocation = PtyProcessInvocation(executable: tool,
            arguments: ["x", "-y", "-o\(destination.path)", "--", root.appendingPathComponent(first).path],
            password: fixture.password, responses: [.password], passwordEchoPolicy: .disableBeforeResponse)
        let result = try PtyProcessRunner().run(invocation)
        XCTAssertEqual(result.status, 0, "Full 7-Zip failed to qualify the reference: \(result.outputString)")
        guard result.status == 0 else { return }
        var actualFiles = Set<String>()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                actualFiles.insert(String(file.path.dropFirst(destination.path.count + 1)))
            }
        }
        XCTAssertEqual(actualFiles, Set(fixture.expected.map(\.name)))
        for expected in fixture.expected {
            let original = try Data(contentsOf: root.appendingPathComponent(expected.reference))
            XCTAssertEqual(original.count, expected.bytes)
            XCTAssertEqual(Self.digest(original), expected.sha256)
            let decoded = try Data(contentsOf: destination.appendingPathComponent(expected.name))
            XCTAssertEqual(decoded, original, expected.name)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let sources: [Source]
        let files: [File]
        let archives: [Archive]
    }

    private struct Source: Decodable {
        let commit: String
        let licenseFile: String
    }

    private struct File: Decodable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    private struct Archive: Decodable {
        let id: String
        let parts: [String]
        let password: String?
        let expected: [Expected]
    }

    private struct Expected: Decodable {
        let name: String
        let reference: String
        let bytes: Int
        let sha256: String
    }
}
