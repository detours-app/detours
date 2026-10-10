import DetoursProcess
import Foundation
import RemoteOperationSupport
import XCTest

extension RarArchiveStreamTests {
    func testReadsAllRarFixtureFamilies() throws {
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("resources/fixtures/rar")
        let manifest = try JSONDecoder().decode(FamilyManifest.self, from: Data(contentsOf: corpus.appendingPathComponent("manifest.json")))
        for archive in manifest.archives where archive.expectedRefusal == nil {
            print("RAR reader family: \(archive.id)")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rar-family-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
            for part in archive.parts {
                try FileManager.default.copyItem(at: corpus.appendingPathComponent(part),
                    to: root.appendingPathComponent(URL(fileURLWithPath: part).lastPathComponent))
            }
            let directory = try OperationDirectory(path: Data(root.path.utf8))
            let selected = URL(fileURLWithPath: try XCTUnwrap(archive.parts.last)).lastPathComponent
            let volumes = try RarVolumeSet.discover(directory: directory, selected: selected, password: archive.password, progress: { _ in })
            let members = try volumes.read(password: archive.password, output: { member in
                let url = root.appendingPathComponent("output-\(member.index)")
                try Data().write(to: url, options: .withoutOverwriting)
                return try FileHandle(forWritingTo: url)
            }, progress: { _ in })
            XCTAssertEqual(Set(members.map(\.name)), Set(archive.expected.map(\.name)), archive.id)
            for expected in archive.expected {
                let member = try XCTUnwrap(members.first { $0.name == expected.name })
                XCTAssertEqual(member.directory, expected.kind == "directory", expected.name)
                if expected.kind == "directory" { continue }
                XCTAssertEqual(member.size, expected.bytes, expected.name)
                if expected.linkType == "HARD_LINK" {
                    XCTAssertEqual(member.hardLink, expected.target)
                    continue
                }
                let bytes = try Data(contentsOf: root.appendingPathComponent("output-\(member.index)"))
                XCTAssertEqual(UInt64(bytes.count), expected.bytes, expected.name)
                if let hash = expected.sha256 { XCTAssertEqual(OperationContentProof.data(bytes).sha256, hash, expected.name) }
                if let crc = expected.crc32, expected.linkType != "FILE_COPY" {
                    XCTAssertEqual(String(format: "%08x", Self.familyCRC(bytes)), crc, expected.name)
                }
                if let reference = expected.reference {
                    var original = try Data(contentsOf: corpus.appendingPathComponent(reference))
                    if expected.referenceLineEndings == "crlf" {
                        original = Data(try XCTUnwrap(String(data: original, encoding: .utf8)).replacingOccurrences(of: "\n", with: "\r\n").utf8)
                    }
                    XCTAssertEqual(bytes, original, expected.name)
                }
            }
            try volumes.validate(progress: { _ in })
        }
    }

    private static func familyCRC(_ bytes: Data) -> UInt32 {
        var value = UInt32.max
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~value
    }
}

private struct FamilyManifest: Decodable {
    let archives: [Archive]
    struct Archive: Decodable {
        let id: String
        let parts: [String]
        let password: String?
        let expectedRefusal: String?
        let expected: [Expected]
    }
    struct Expected: Decodable {
        let name: String
        let bytes: UInt64
        let kind: String?
        let sha256: String?
        let crc32: String?
        let reference: String?
        let referenceLineEndings: String?
        let linkType: String?
        let target: String?
    }
}
