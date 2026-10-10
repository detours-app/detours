import DetoursProcess
import RemoteOperationSupport
import XCTest
@testable import Detours

@MainActor
final class RarArchiveOperationTests: XCTestCase {
    func testRecognizesRarSetsWithoutOfferingRarCreation() async throws {
        XCTAssertEqual(ArchiveFormat.writableFormats, [.zip, .sevenZ, .tarGz, .tarBz2, .tarXz])
        XCTAssertFalse(ArchiveFormat.rar.supportsCreation)
        XCTAssertFalse(CompressionTools.isFormatAvailable(.rar))
        XCTAssertNil(ArchivePasswordValidation.errorMessage(for: String(repeating: "x", count: 200), format: .rar))
        for name in ["received.rar", "received.RAR", "received.Part003.RaR", "received.r00", "received.R01"] {
            XCTAssertTrue(RarVolumeSet.isCandidate(name))
        }
        for name in ["notes.001", "notes.r0", "notes.r000", "../received.rar", "C:received.rar"] {
            XCTAssertFalse(RarVolumeSet.isCandidate(name))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detours-rar-recognition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("resources/fixtures/rar/rarfile")
        let plain = root.appendingPathComponent("received.RAR")
        try Data(contentsOf: fixtures.appendingPathComponent("seektest.rar")).write(to: plain, options: .withoutOverwriting)
        XCTAssertEqual(ArchiveFormat.detect(from: plain), .rar)
        let single = try RarVolumeSet.discover(directory: directory, selected: plain.lastPathComponent, password: nil, progress: { _ in })
        XCTAssertEqual(single.parts.map(\.name), ["received.RAR"])
        XCTAssertEqual(single.baseName, "received")
        for index in 1...3 {
            try Data(contentsOf: fixtures.appendingPathComponent("rar5-vols.part\(index).rar"))
                .write(to: root.appendingPathComponent("set.Part00\(index).RaR"), options: .withoutOverwriting)
        }
        let split = try RarVolumeSet.discover(directory: directory, selected: "set.Part003.RaR", password: nil, progress: { _ in })
        XCTAssertEqual(split.parts.map(\.name), (1...3).map { "set.Part00\($0).RaR" })
        XCTAssertEqual(split.baseName, "set")
        for name in ["notes.r00", "notes.part1.rar"] {
            try Data("ordinary numbered file".utf8).write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
            XCTAssertThrowsError(try RarVolumeSet.discover(directory: directory, selected: name, password: nil, progress: { _ in })) {
                XCTAssertEqual($0 as? SevenZipArchiveError, .corruptArchive)
            }
        }
        let before = try directory.names()
        do {
            _ = try await FileOperationQueue.shared.archive(items: [plain], format: .rar, archiveName: "forbidden", password: nil)
            XCTFail("RAR creation must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("only be extracted"))
        }
        XCTAssertEqual(try directory.names(), before)
        let account = OperationAccount(hostIdentity: "host", accountIdentity: "account")
        let legacy = OperationHandshake(version: OperationHandshake.protocolVersion, schemaVersion: OperationHandshake.journalSchema,
                                        capabilities: OperationCapability.baseline, account: account, epoch: UUID())
        XCTAssertNoThrow(try legacy.validate(expectedAccount: account, expectedEpoch: nil))
        XCTAssertFalse(legacy.capabilities.contains(.rarExtraction))
    }
}
