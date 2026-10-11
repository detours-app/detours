import Foundation
import RemoteOperationSupport
import XCTest
@testable import DetoursProcess

extension RarArchiveStreamTests {
    func testVolumeCallbacksRefuseUnacceptedPaths() throws {
        let fixture = try VolumeFixture()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: fixture.root)) }
        for names in [VolumeFixture.modern, VolumeFixture.legacy, VolumeFixture.sharp] {
            let folder = try fixture.copy(names)
            let password = names == VolumeFixture.sharp ? "test" : nil
            let set = try RarVolumeSet.discover(directory: folder, selected: try XCTUnwrap(names.last), password: password,
                                                progress: { _ in })
            XCTAssertEqual(set.parts.map(\.name), names)
            XCTAssertTrue(set.parts.allSatisfy { $0.observation.sha256 != nil })
            XCTAssertFalse(set.members.isEmpty)
            let accepted = try RarVolumeSet.accepted(directory: folder, parts: set.parts, password: password, progress: { _ in })
            XCTAssertEqual(accepted.members, set.members)
            XCTAssertThrowsError(try RarVolumeSet.accepted(directory: folder, parts: Array(set.parts.reversed()), password: password, progress: { _ in }))
            try fixture.bytes("seektest.rar").write(to: fixture.url(folder, "extra.rar"))
            let extra = RarVolumeSet.Part(name: "extra.rar", observation: try folder.proveFile(Data("extra.rar".utf8), progress: { _ in }))
            XCTAssertThrowsError(try RarVolumeSet.accepted(directory: folder, parts: set.parts + [extra], password: password, progress: { _ in }))
        }
        for missing in VolumeFixture.modern {
            let folder = try fixture.copy(VolumeFixture.modern.filter { $0 != missing })
            let selected = missing == VolumeFixture.modern[0] ? VolumeFixture.modern[1] : VolumeFixture.modern[0]
            XCTAssertThrowsError(try RarVolumeSet.discover(directory: folder, selected: selected, password: nil, progress: { _ in })) {
                XCTAssertEqual($0 as? SevenZipArchiveError, .missingVolume(missing))
            }
        }
        let mixed = try fixture.copy(VolumeFixture.modern)
        try fixture.bytes("rar5-crc.rar").write(to: fixture.url(mixed, VolumeFixture.modern[1]))
        XCTAssertThrowsError(try RarVolumeSet.discover(directory: mixed, selected: VolumeFixture.modern[0], password: nil, progress: { _ in })) {
            XCTAssertEqual($0 as? SevenZipArchiveError, .inconsistentVolumes(VolumeFixture.modern[1]))
        }
        let substituted = try fixture.copy(VolumeFixture.modern)
        let observed = try RarVolumeSet.discover(directory: substituted, selected: VolumeFixture.modern[0], password: nil, progress: { _ in })
        let displaced = try fixture.url(substituted, VolumeFixture.modern[1])
        let saved = try fixture.url(substituted, "saved-part")
        try FileManager.default.moveItem(at: displaced, to: saved)
        try FileManager.default.createSymbolicLink(at: displaced, withDestinationURL: saved)
        XCTAssertThrowsError(try observed.read(password: nil, progress: { _ in }))
        XCTAssertThrowsError(try observed.validate(progress: { _ in }))
        XCTAssertThrowsError(try RarVolumeSet.resolve("set.rar", among: ["set.rar", "SET.RAR"])) {
            XCTAssertEqual($0 as? SevenZipArchiveError, .ambiguousVolumes("set.rar"))
        }
        let excessive = Array(repeating: try XCTUnwrap(observed.parts.first), count: 1_025)
        XCTAssertThrowsError(try RarVolumeSet.accepted(directory: substituted, parts: excessive, password: nil, progress: { _ in })) {
            XCTAssertEqual($0 as? SevenZipArchiveError, .volumeLimitExceeded)
        }
        try checkVolumeCallbacks(fixture)
    }

    private func checkVolumeCallbacks(_ fixture: VolumeFixture) throws {
        let first = try FileHandle(forReadingFrom: fixture.source(VolumeFixture.modern[0]))
        defer { XCTAssertNoThrow(try first.close()) }
        for unsafe in ["../set.part1.rar", "/set.part1.rar", "C:set.part1.rar", "folder\\set.part1.rar"] {
            let opened = VolumeHandles()
            XCTAssertThrowsError(try SevenZipArchiveReader.read(input: first, format: .rar5, password: nil,
                inputName: unsafe, openVolume: { _ in
                    let handle = try FileHandle(forReadingFrom: fixture.source(VolumeFixture.modern[1]))
                    opened.append(handle)
                    return handle
                }, progress: { _ in }))
            XCTAssertTrue(opened.snapshot.isEmpty, unsafe)
        }
        let opened = VolumeHandles()
        XCTAssertThrowsError(try SevenZipArchiveReader.read(input: first, format: .rar5, password: nil,
            inputName: VolumeFixture.modern[0], openVolume: { _ in
                let handle = try FileHandle(forReadingFrom: fixture.source(VolumeFixture.modern[1]))
                opened.append(handle)
                return handle
            }, progress: { _ in })) {
                XCTAssertEqual($0 as? SevenZipArchiveError, .volumeLimitExceeded)
            }
        XCTAssertGreaterThanOrEqual(opened.snapshot.count, 1_023)
        for handle in opened.snapshot { XCTAssertThrowsError(try handle.read(upToCount: 1)) }
    }

    private struct VolumeFixture: Sendable {
        static let modern = (1...3).map { "rar5-vols.part\($0).rar" }
        static let legacy = ["rar3-old.rar", "rar3-old.r00", "rar3-old.r01"]
        static let sharp = (1...6).map { "Rar.EncryptedParts.part0\($0).rar" }
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("detours-rar-volumes-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func source(_ name: String) -> URL {
            let family = name.hasPrefix("Rar.") ? "sharpcompress" : "rarfile"
            return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("resources/fixtures/rar/\(family)/\(name)")
        }

        func bytes(_ name: String) throws -> Data { try Data(contentsOf: source(name)) }

        func copy(_ names: [String]) throws -> OperationDirectory {
            let folder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for name in names { try bytes(name).write(to: folder.appendingPathComponent(name), options: .withoutOverwriting) }
            return try OperationDirectory(path: Data(folder.path.utf8))
        }

        func url(_ directory: OperationDirectory, _ name: String) throws -> URL {
            URL(fileURLWithPath: try XCTUnwrap(String(data: directory.path, encoding: .utf8))).appendingPathComponent(name)
        }
    }

    private final class VolumeHandles: @unchecked Sendable {
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
}
