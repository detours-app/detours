import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import DetoursProcess

extension RarArchiveOperationTests {
    func testMultipartExtractionUsesEveryObservedPart() async throws {
        let queue = FileOperationQueue.shared
        defer { queue.rarExtractionProbeForTesting = nil }
        for names in [
            (1...3).map { "rarfile/rar5-vols.part\($0).rar" },
            ["rarfile/rar3-old.rar", "rarfile/rar3-old.r00", "rarfile/rar3-old.r01"],
            (1...6).map { "sharpcompress/Rar.EncryptedParts.part0\($0).rar" }
        ] {
            let fixture = try RarLocalFixture(names)
            defer { fixture.cleanup() }
            let encrypted = names.count == 6
            let selected = try XCTUnwrap(fixture.parts.last)
            let result = try await queue.extract(archive: selected, password: encrypted ? "test" : nil)
            if encrypted {
                XCTAssertEqual(result.lastPathComponent, "Rar.EncryptedParts")
                for name in ["exe/test.exe", "jpg/test.jpg", "тест.txt"] {
                    var expected = try Data(contentsOf: RarLocalFixture.source("references/sharpcompress/\(name)"))
                    if name.hasSuffix(".txt") {
                        expected = Data(try XCTUnwrap(String(data: expected, encoding: .utf8)).replacingOccurrences(of: "\n", with: "\r\n").utf8)
                    }
                    XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent(name)), expected)
                }
            } else {
                XCTAssertEqual(result.lastPathComponent, "vols")
                let big = try Data(contentsOf: result.appendingPathComponent("bigfile.txt"))
                let small = try Data(contentsOf: result.appendingPathComponent("smallfile.txt"))
                XCTAssertEqual(big.count, 205_000)
                XCTAssertEqual(small.count, 2_050)
                XCTAssertEqual(RarLocalFixture.crc32(big), 0x509ad74c)
                XCTAssertEqual(RarLocalFixture.crc32(small), 0xd08a1f86)
            }
            try fixture.assertSourcesUnchanged()
            try fixture.assertNoScratch()
        }
        for stage in [RarExtractionStage.discovered, .prepared, .publishing] {
            let fixture = try RarLocalFixture((1...3).map { "rarfile/rar5-vols.part\($0).rar" })
            defer { fixture.cleanup() }
            let changed = fixture.parts[1]
            queue.rarExtractionProbeForTesting = { current, _ in
                if current == stage {
                    var bytes = try Data(contentsOf: changed)
                    bytes[bytes.count / 2] ^= 1
                    try bytes.write(to: changed)
                }
            }
            await fixture.assertRefused(queue, archive: fixture.parts[2])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("vols").path))
            try fixture.assertNoScratch()
        }
        queue.rarExtractionProbeForTesting = nil
        let fixture = try RarLocalFixture(["rarfile/rar5-psw.rar"])
        defer { fixture.cleanup() }
        let secret = "unique-wrong-secret-privacy-check"
        do {
            _ = try await queue.extract(archive: fixture.parts[0], password: secret)
            XCTFail("Incorrect password accepted")
        } catch {
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
        XCTAssertFalse(String(describing: queue.lastFinishedOperation).contains(secret))
        try fixture.assertNoScratch()
    }

    func testUnsafeOrDamagedRarCannotPublish() async throws {
        let queue = FileOperationQueue.shared
        defer { queue.rarExtractionProbeForTesting = nil }
        let original = try Data(contentsOf: RarLocalFixture.source("rarfile/seektest.rar"))
        let copies = [
            try RarLocalFixture.renaming(original, from: "stest1.txt", to: "../bad.txt"),
            try RarLocalFixture.renaming(original, from: "stest2.txt", to: "stest1.txt"),
            Data(original.dropLast(100)),
            try Data(contentsOf: RarLocalFixture.source("rarfile/rar5-evil-symlink-traversal.rar")),
            try Data(contentsOf: RarLocalFixture.source("rarfile/rar3-symlink-unix.rar"))
        ]
        for bytes in copies {
            let fixture = try RarLocalFixture([])
            defer { fixture.cleanup() }
            let archive = fixture.root.appendingPathComponent("received.rar")
            try bytes.write(to: archive, options: .withoutOverwriting)
            let occupant = fixture.root.appendingPathComponent("received")
            try Data("existing".utf8).write(to: occupant)
            await fixture.assertRefused(queue, archive: archive)
            XCTAssertEqual(try Data(contentsOf: occupant), Data("existing".utf8))
            XCTAssertEqual(try Data(contentsOf: archive), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(), ["received", "received.rar"])
        }
        let fixture = try RarLocalFixture(["rarfile/seektest.rar"])
        defer { fixture.cleanup() }
        queue.rarExtractionProbeForTesting = { stage, _ in if stage == .output { throw POSIXError(.ENOSPC) } }
        await fixture.assertRefused(queue, archive: fixture.parts[0])
        try fixture.assertSourcesUnchanged()
        try fixture.assertNoScratch()
        let directory = try OperationDirectory(path: Data(fixture.root.path.utf8))
        let set = try RarVolumeSet.discover(directory: directory, selected: "seektest.rar", password: nil, progress: { _ in })
        XCTAssertThrowsError(try RarExtractionStaging(volumes: set, password: nil, caseSensitive: false,
            availableBytes: 1, progress: { _ in }, beforeOutput: {})) { XCTAssertEqual(($0 as? POSIXError)?.code, .ENOSPC) }
        let first = try XCTUnwrap(set.members.first)
        let equivalent = SevenZipArchiveReader.Member(index: 1, name: first.name.uppercased(), symbolicLink: nil,
            hardLink: nil, size: first.size, modified: first.modified, mode: first.mode, directory: false,
            encrypted: false, splitBefore: false, splitAfter: false)
        XCTAssertThrowsError(try RarExtractionPlan([first, equivalent], caseSensitive: false))
        try fixture.assertNoScratch()
    }

    func testRarConflictCancellationAndUndoPreserveFiles() async throws {
        let queue = FileOperationQueue.shared
        queue.forceLocalDisplacementFallbackForTesting = true
        defer {
            queue.forceLocalDisplacementFallbackForTesting = false
            queue.conflictChoiceOverrideForTesting = nil
            queue.rarExtractionProbeForTesting = nil
        }
        for choice in [FileOperationQueue.ConflictChoice.keepBoth, .replace, .skip] {
            let fixture = try RarLocalFixture(["rarfile/seektest.rar"])
            defer { fixture.cleanup() }
            let occupant = fixture.root.appendingPathComponent("seektest")
            try Data("existing".utf8).write(to: occupant)
            queue.conflictChoiceOverrideForTesting = choice
            if choice == .skip {
                await fixture.assertRefused(queue, archive: fixture.parts[0])
            } else {
                let undo = UndoManager()
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                let result = try await queue.extract(archive: fixture.parts[0], undoManager: undo)
                undo.endUndoGrouping()
                XCTAssertEqual(result.lastPathComponent, choice == .replace ? "seektest" : "seektest 2")
                XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("stest1.txt")), RarLocalFixture.seekBytes)
                XCTAssertTrue(undo.canUndo)
                undo.undo()
                XCTAssertFalse(FileManager.default.fileExists(atPath: result.appendingPathComponent("stest1.txt").path))
            }
            XCTAssertEqual(try Data(contentsOf: occupant), Data("existing".utf8))
            try fixture.assertSourcesUnchanged()
            try fixture.assertNoScratch()
        }
        queue.conflictChoiceOverrideForTesting = .replace
        for stage in [RarExtractionStage.output, .prepared, .publishing, .published] {
            let fixture = try RarLocalFixture(["rarfile/seektest.rar"])
            defer { fixture.cleanup() }
            queue.rarExtractionProbeForTesting = { current, cancellation in if current == stage { cancellation.cancel() } }
            if stage == .published {
                let result = try await queue.extract(archive: fixture.parts[0])
                XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("stest2.txt")), RarLocalFixture.seekBytes)
            } else {
                await fixture.assertRefused(queue, archive: fixture.parts[0])
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("seektest").path))
            }
            try fixture.assertSourcesUnchanged()
            try fixture.assertNoScratch()
        }
        for replacing in [false, true] {
            let fixture = try RarLocalFixture(["rarfile/seektest.rar"])
            defer { fixture.cleanup() }
            let target = fixture.root.appendingPathComponent("seektest")
            if replacing { try Data("old".utf8).write(to: target) }
            queue.rarExtractionProbeForTesting = { stage, _ in
                if stage == .publishing { try Data("racing occupant".utf8).write(to: target) }
            }
            await fixture.assertRefused(queue, archive: fixture.parts[0])
            XCTAssertEqual(try Data(contentsOf: target), Data("racing occupant".utf8))
            try fixture.assertNoScratch()
        }
    }
}

private struct RarLocalFixture {
    let root: URL
    let parts: [URL]
    let originals: [Data]
    static var seekBytes: Data { Data((0..<512).map { String(format: "%03d\n", $0) }.joined().utf8) }

    init(_ names: [String]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("detours-local-rar-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        parts = names.map { root.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent) }
        originals = try names.map { try Data(contentsOf: Self.source($0)) }
        for (url, bytes) in zip(parts, originals) { try bytes.write(to: url, options: .withoutOverwriting) }
    }
    static func source(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("resources/fixtures/rar/\(name)")
    }
    func cleanup() { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
    func assertSourcesUnchanged() throws {
        for (url, bytes) in zip(parts, originals) { XCTAssertEqual(try Data(contentsOf: url), bytes) }
    }
    func assertNoScratch() throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".detours-") })
    }
    @MainActor func assertRefused(_ queue: FileOperationQueue, archive: URL) async {
        do {
            _ = try await queue.extract(archive: archive)
            XCTFail("Extraction unexpectedly published \(archive.lastPathComponent)")
        } catch { XCTAssertFalse(String(describing: error).isEmpty) }
    }
    static func renaming(_ original: Data, from source: String, to target: String) throws -> Data {
        guard source.utf8.count == target.utf8.count else { throw SevenZipArchiveError.invalidEntry }
        var bytes = original
        var offset = 7
        while offset + 7 <= bytes.count {
            let length = Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
            guard length >= 7, offset + length <= bytes.count else { throw SevenZipArchiveError.invalidEntry }
            var packed = 0
            if bytes[offset + 2] == 0x74 {
                packed = (0..<4).reduce(0) { $0 | Int(bytes[offset + 7 + $1]) << (8 * $1) }
                if let range = bytes.range(of: Data(source.utf8), in: (offset + 7)..<(offset + length)) {
                    bytes.replaceSubrange(range, with: target.utf8)
                    let checksum = crc32(bytes.subdata(in: (offset + 2)..<(offset + length)))
                    bytes[offset] = UInt8(truncatingIfNeeded: checksum)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: checksum >> 8)
                    return bytes
                }
            }
            offset += length + packed
        }
        throw SevenZipArchiveError.invalidEntry
    }
    static func crc32(_ bytes: Data) -> UInt32 {
        var value = UInt32.max
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~value
    }
}
