import DetoursProcess
import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerArchiveStreamTests: XCTestCase {
    func testNativeSevenZipRoundTripRetainsOwnedOutputAndTreeContents() throws {
        for password in [nil, "fixture password 🗝"] as [String?] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let source = try FileHandle(forReadingFrom: fixture.source)
            defer { try? source.close() }
            let output = try SafeFileWriter.createHandle(at: fixture.archive)
            defer { try? output.close() }
            let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
            let before = try parent.observe(Data("owned.7z".utf8))
            let entries = [
                fixture.entry("folder", directory: true),
                fixture.entry("folder/empty", directory: true),
                fixture.entry("folder/émoji 📁.txt", input: source, size: UInt64(fixture.bytes.count)),
                fixture.entry("folder/link", target: Data("émoji 📁.txt".utf8)),
            ]
            try SevenZipArchiveWriter.create(entries: entries, output: output, password: password, progress: { _ in })
            XCTAssertEqual(try parent.observe(Data("owned.7z".utf8)).identity, before.identity)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            let extracted = try ArchiveOperations().extractArchive(archive: fixture.archive.path, password: password)
            let folder = URL(fileURLWithPath: extracted)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("émoji 📁.txt")), fixture.bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("empty").path), [])
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path), "émoji 📁.txt")
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("link")), fixture.bytes)
            if password != nil {
                XCTAssertThrowsError(try ArchiveOperations().extractArchive(archive: fixture.archive.path, password: "wrong fixture password")) {
                    XCTAssertEqual($0 as? ArchiveOperationsError, .wrongPassword)
                }
            }
        }
    }

    func testExternalLinkArchiveRetainsExistingExtractionRefusal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let output = try SafeFileWriter.createHandle(at: fixture.archive)
        defer { try? output.close() }
        try SevenZipArchiveWriter.create(
            entries: [fixture.entry("folder", directory: true), fixture.entry("folder/link", target: Data("../outside".utf8))],
            output: output, password: nil, progress: { _ in }
        )
        XCTAssertThrowsError(try ArchiveOperations().extractArchive(archive: fixture.archive.path, password: nil)) {
            guard case .processFailed(let detail) = $0 as? ArchiveOperationsError else {
                return XCTFail("Expected existing unsafe-link extraction refusal, got \($0)")
            }
            XCTAssertTrue(detail.contains("Dangerous link path was ignored") ||
                          detail.contains("Dangerous symbolic link path was ignored"), detail)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("outside")), Data("outside survives".utf8))
    }

    func testCancellationStopsNativeCompressionWithoutReplacingOutputOrSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try FileHandle(forReadingFrom: fixture.source)
        let output = try SafeFileWriter.createHandle(at: fixture.archive)
        defer {
            try? source.close()
            try? output.close()
        }
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        let before = try parent.observe(Data("owned.7z".utf8))
        enum Cancelled: Error { case requested }
        XCTAssertThrowsError(try SevenZipArchiveWriter.create(
            entries: [fixture.entry("file", input: source, size: UInt64(fixture.bytes.count))],
            output: output, password: nil, progress: { count in
                if count > 0 { throw Cancelled.requested }
            }
        )) { XCTAssertTrue($0 is Cancelled) }
        XCTAssertEqual(try parent.observe(Data("owned.7z".utf8)).identity, before.identity)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    func testNonemptyOutputAndUnsafeMemberNamesAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let output = try SafeFileWriter.createHandle(at: fixture.archive)
        defer { try? output.close() }
        try output.write(contentsOf: Data("keep".utf8))
        XCTAssertThrowsError(try SevenZipArchiveWriter.create(entries: [], output: output, password: nil, progress: { _ in }))
        XCTAssertEqual(try Data(contentsOf: fixture.archive), Data("keep".utf8))
        for name in ["../escape", "/absolute", "folder//empty", "folder/../escape", "a\0b"] {
            XCTAssertThrowsError(try SevenZipArchiveWriter.create(
                entries: [fixture.entry(name, directory: true)], output: output, password: nil, progress: { _ in }
            )) { XCTAssertEqual($0 as? SevenZipArchiveError, .invalidEntry) }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), Data("keep".utf8))
    }

    func testDeferredInputsOpenOnlyWhenUsedAndCloseAfterEachMember() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let output = try SafeFileWriter.createHandle(at: fixture.archive)
        defer { try? output.close() }
        let source = fixture.source
        let handles = OpenedHandles()
        let entries = (0..<16).map { index in
            SevenZipArchiveWriter.Entry(name: "member-\(index)", input: nil, size: UInt64(fixture.bytes.count),
                                        directory: false, mode: 0o100640, modified: Date(timeIntervalSince1970: 1_600_000_000),
                                        openInput: {
                let input = try FileHandle(forReadingFrom: source)
                handles.append(input)
                return input
            })
        }
        XCTAssertTrue(handles.snapshot.isEmpty)
        try SevenZipArchiveWriter.create(entries: entries, output: output, password: nil, progress: { _ in })
        XCTAssertEqual(handles.snapshot.count, 16)
        for handle in handles.snapshot { XCTAssertThrowsError(try handle.read(upToCount: 1)) }
        let extracted = URL(fileURLWithPath: try ArchiveOperations().extractArchive(archive: fixture.archive.path, password: nil))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extracted.path).count, 16)
        for index in 0..<16 { XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("member-\(index)")), fixture.bytes) }
    }

    func testDeferredInputFailurePropagatesWithoutChangingSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let output = try SafeFileWriter.createHandle(at: fixture.archive)
        defer { try? output.close() }
        let entry = SevenZipArchiveWriter.Entry(name: "refused", input: nil, size: 1, directory: false,
                                                mode: 0o100600, modified: Date(), openInput: {
            throw OperationFilesystemError.identityChanged
        })
        XCTAssertThrowsError(try SevenZipArchiveWriter.create(entries: [entry], output: output, password: nil, progress: { _ in })) {
            XCTAssertEqual($0 as? OperationFilesystemError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    private final class OpenedHandles: @unchecked Sendable {
        private let lock = NSLock()
        private var handles: [FileHandle] = []

        func append(_ handle: FileHandle) {
            lock.lock()
            defer { lock.unlock() }
            handles.append(handle)
        }

        var snapshot: [FileHandle] {
            lock.lock()
            defer { lock.unlock() }
            return handles
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let archive: URL
        let bytes = Data(repeating: 42, count: 131_073)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            source = root.appendingPathComponent("source")
            archive = root.appendingPathComponent("owned.7z")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try bytes.write(to: source)
            try Data("outside survives".utf8).write(to: root.appendingPathComponent("outside"))
        }

        func entry(_ name: String, input: FileHandle? = nil, size: UInt64 = 0,
                   directory: Bool = false, target: Data? = nil) -> SevenZipArchiveWriter.Entry {
            .init(name: name, input: input, size: size, directory: directory,
                  mode: directory ? 0o40755 : (target != nil ? 0o120777 : 0o100640),
                  modified: Date(timeIntervalSince1970: 1_600_000_000), linkTarget: target)
        }

        func cleanup() { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
    }
}
