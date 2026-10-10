import Foundation
import RemoteOperationSupport
import XCTest

struct RarTestCorpus: Decodable {
    let archives: [Archive]
    struct Archive: Decodable {
        let id: String
        let parts: [String]
        let password: String?
        let expectedRefusal: String?
        let expected: [Expected]
        var rootName: String? {
            let roots = Set(expected.compactMap { $0.name.split(separator: "/").first.map(String.init) })
            return roots.count == 1 ? roots.first : nil
        }
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
        let modified: String?

        func assertBytes(_ data: Data) throws {
            XCTAssertEqual(UInt64(data.count), bytes, name)
            if let sha256 { XCTAssertEqual(OperationContentProof.data(data).sha256, sha256, name) }
            if let crc32, linkType != "HARD_LINK", linkType != "FILE_COPY" {
                XCTAssertEqual(String(format: "%08x", RarTestCorpus.crc(data)), crc32, name)
            }
            if let reference {
                var original = try Data(contentsOf: RarTestCorpus.source(reference))
                if referenceLineEndings == "crlf" {
                    original = Data(try XCTUnwrap(String(data: original, encoding: .utf8)).replacingOccurrences(of: "\n", with: "\r\n").utf8)
                }
                XCTAssertEqual(data, original, name)
            }
        }
    }

    static func load() throws -> RarTestCorpus {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: source("manifest.json")))
    }
    static func source(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("resources/fixtures/rar/\(name)")
    }
    static func crc(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~value
    }
}
