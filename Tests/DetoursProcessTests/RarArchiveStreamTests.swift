import DetoursProcess
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class RarArchiveStreamTests: XCTestCase {
    func testSeparatesPasswordIntegrityAndCancellation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for name in ["rar5-psw.rar", "rar5-hpsw.rar", "rar3-comment-psw.rar", "rar3-comment-hpsw.rar"] {
            let format: SevenZipArchiveReader.Format = name.hasPrefix("rar5") ? .rar5 : .rar
            XCTAssertThrowsError(try fixture.decode(name, format: format, password: nil)) {
                XCTAssertEqual($0 as? SevenZipArchiveError, .passwordRequired, name)
            }
            XCTAssertThrowsError(try fixture.decode(name, format: format, password: "incorrect")) {
                let expected: SevenZipArchiveError = name == "rar5-psw.rar" ? .wrongPassword : .passwordOrCorruption
                XCTAssertEqual($0 as? SevenZipArchiveError, expected, name)
            }
            let decoded = try fixture.decode(name, format: format, password: "password")
            XCTAssertEqual(decoded.count, 2, name)
            let expected = name.hasPrefix("rar5") ? Self.seekBytes : Data()
            for bytes in decoded { XCTAssertEqual(bytes, expected, name) }
        }
        let original = try Data(contentsOf: fixture.source("seektest.rar"))
        var damaged = original
        let stored = try XCTUnwrap(damaged.range(of: Self.seekBytes))
        damaged[stored.lowerBound] ^= 1
        let damagedURL = try fixture.copy(damaged)
        XCTAssertThrowsError(try fixture.decode(damagedURL, format: .rar, password: nil)) {
            XCTAssertEqual($0 as? SevenZipArchiveError, .corruptArchive)
        }
        var encrypted = try Data(contentsOf: fixture.source("rar5-psw.rar"))
        encrypted[encrypted.count - 32] ^= 1
        let encryptedURL = try fixture.copy(encrypted)
        XCTAssertThrowsError(try fixture.decode(encryptedURL, format: .rar5, password: "password")) {
            XCTAssertEqual($0 as? SevenZipArchiveError, .passwordOrCorruption)
        }
        let mismatched = try fixture.copy(Self.wrongDeclaredSize(original))
        XCTAssertThrowsError(try fixture.decode(mismatched, format: .rar, password: nil)) {
            XCTAssertEqual($0 as? SevenZipArchiveError, .corruptArchive)
        }
        let cancelled = Handles()
        let input = try FileHandle(forReadingFrom: fixture.source("seektest.rar"))
        defer { XCTAssertNoThrow(try input.close()) }
        let outputRoot = fixture.root
        XCTAssertThrowsError(try SevenZipArchiveReader.read(input: input, format: .rar, password: nil, output: { _ in
            let handle = try Self.emptyHandle(outputRoot.appendingPathComponent(UUID().uuidString))
            cancelled.append(handle)
            return handle
        }, progress: { _ in
            if !cancelled.snapshot.isEmpty { throw Cancelled.requested }
        })) { XCTAssertTrue($0 is Cancelled) }
        XCTAssertFalse(cancelled.snapshot.isEmpty)
        for handle in cancelled.snapshot { XCTAssertThrowsError(try handle.write(contentsOf: Data([1]))) }
        XCTAssertEqual(try Data(contentsOf: fixture.source("seektest.rar")), original)
        for handle in fixture.handles.snapshot { XCTAssertThrowsError(try handle.write(contentsOf: Data([1]))) }
    }

    private static var seekBytes: Data {
        Data((0..<512).map { String(format: "%03d\n", $0) }.joined().utf8)
    }

    private static func wrongDeclaredSize(_ original: Data) throws -> Data {
        var bytes = original
        var offset = 7
        while offset + 7 <= bytes.count {
            let length = Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
            guard length >= 7, offset + length <= bytes.count else { throw SevenZipArchiveError.invalidEntry }
            let type = bytes[offset + 2]
            let packed: Int
            if type == 0x74 {
                packed = (0..<4).reduce(0) { $0 | Int(bytes[offset + 7 + $1]) << (8 * $1) }
                if bytes[offset + 25] == 0x30, packed == 2048 {
                    bytes[offset + 11] = 0xff
                    bytes[offset + 12] = 0x07
                    let checksum = crc32(bytes.subdata(in: (offset + 2)..<(offset + length)))
                    bytes[offset] = UInt8(truncatingIfNeeded: checksum)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: checksum >> 8)
                    return bytes
                }
            } else {
                packed = 0
            }
            offset += length + packed
        }
        throw SevenZipArchiveError.invalidEntry
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var value = UInt32.max
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~value
    }

    private static func emptyHandle(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SevenZipArchiveError.inputFailure(errno) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private enum Cancelled: Error { case requested }

    private final class Handles: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [FileHandle] = []
        func append(_ handle: FileHandle) {
            lock.lock()
            defer { lock.unlock() }
            values.append(handle)
        }
        var snapshot: [FileHandle] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private struct Fixture {
        let root: URL
        let handles = Handles()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("detours-rar-stream-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func source(_ name: String) -> URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("resources/fixtures/rar/rarfile/\(name)")
        }
        func copy(_ bytes: Data) throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString + ".rar")
            try bytes.write(to: url, options: .withoutOverwriting)
            return url
        }
        func decode(_ name: String, format: SevenZipArchiveReader.Format, password: String?) throws -> [Data] {
            try decode(source(name), format: format, password: password)
        }
        func decode(_ url: URL, format: SevenZipArchiveReader.Format, password: String?) throws -> [Data] {
            let input = try FileHandle(forReadingFrom: url)
            defer { XCTAssertNoThrow(try input.close()) }
            let output = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let opened = handles
            let members = try SevenZipArchiveReader.read(input: input, format: format, password: password, output: { member in
                let handle = try RarArchiveStreamTests.emptyHandle(output.appendingPathComponent(String(member.index)))
                opened.append(handle)
                return handle
            }, progress: { _ in })
            return try members.filter { !$0.directory }.map { try Data(contentsOf: output.appendingPathComponent(String($0.index))) }
        }
        func cleanup() { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
    }
}
