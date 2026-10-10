import DetoursProcess
import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerRarExtractionTests: XCTestCase {
    func testAcceptedRarVerifiesAllPartsAndCommitsOnce() async throws {
        let corpus = try RarTestCorpus.load()
        for archive in corpus.archives where archive.expectedRefusal == nil {
            print("RAR helper family: \(archive.id)")
            let fixture = try await Fixture(archive)
            defer { fixture.cleanup() }
            let selected = try XCTUnwrap(fixture.intent.sources.last)
            guard case .archiveLayout(.found(let layout)) = try fixture.service.archiveLayout(selected, format: "rar", password: archive.password) else {
                return XCTFail("Missing RAR layout")
            }
            XCTAssertEqual(layout.rarSources, fixture.intent.sources)
            XCTAssertEqual(layout.rarObservations, fixture.intent.sourceObservations)
            XCTAssertEqual(layout.singleRoot, archive.rootName)
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let ready = try await fixture.service.prepareArchive(fixture.identity, password: archive.password)
            XCTAssertEqual(ready.phase, .readyToCommit)
            XCTAssertTrue(ready.contentVerified)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            let repeatedReady = try await fixture.service.prepareArchive(fixture.identity, password: nil)
            XCTAssertEqual(repeatedReady, ready)
            let committed = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(committed.outcome, .committed)
            XCTAssertEqual(committed.effects.count, 1)
            try fixture.assertOutput()
            try fixture.assertOriginals()
            try fixture.assertPrivate()
            try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("saved"))
            try Data("later occupant".utf8).write(to: fixture.destination)
            let repeated = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(repeated, committed)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("later occupant".utf8))
        }
        let multipart = try XCTUnwrap(corpus.archives.first { $0.id == "rar5-vols.part1" })
        for beforePrepare in [true, false] {
            let fixture = try await Fixture(multipart)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            if !beforePrepare { _ = try await fixture.service.prepareArchive(fixture.identity, password: nil) }
            try Data("changed continuation".utf8).write(to: fixture.parts[1])
            do {
                if beforePrepare { _ = try await fixture.service.prepareArchive(fixture.identity, password: nil) }
                _ = try await fixture.service.commit(fixture.identity)
                XCTFail("Changed continuation was published")
            } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
        }
    }

    func testRarFailurePreservesFilesAndPasswordPrivacy() async throws {
        let corpus = try RarTestCorpus.load()
        for id in ["rar5-psw", "rar5-hpsw", "rar3-comment-hpsw", "encrypted-multipart-rar4",
                   "rar3-symlink-unix", "rar5-evil-symlink-traversal", "rar5-symlink-unix", "rar5-symlink-win"] {
            let archive = try XCTUnwrap(corpus.archives.first { $0.id == id })
            let fixture = try await Fixture(archive)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let secret = "rar-helper-private-wrong-password-73419"
            do {
                _ = try await fixture.service.prepareArchive(fixture.identity, password: archive.password == nil ? nil : secret)
                XCTFail("Invalid RAR prepared: \(id)")
            } catch {
                XCTAssertFalse(String(describing: error).contains(secret))
                if id == "rar5-psw" { XCTAssertEqual(error as? SevenZipArchiveError, .wrongPassword) }
            }
            try fixture.assertFailed(secret: secret)
        }
        let multipart = try XCTUnwrap(corpus.archives.first { $0.id == "rar5-vols.part1" })
        for index in 0..<multipart.parts.count {
            let fixture = try await Fixture(multipart)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            try FileManager.default.removeItem(at: fixture.parts[index])
            do {
                _ = try await fixture.service.prepareArchive(fixture.identity, password: nil)
                XCTFail("Missing part prepared")
            } catch { XCTAssertFalse(error is CancellationError) }
            try fixture.assertFailed(unchangedSources: false)
            let selectedIndex = index == 0 ? 2 : 0
            XCTAssertThrowsError(try fixture.service.archiveLayout(fixture.intent.sources[selectedIndex], format: "rar", password: nil)) {
                guard case SevenZipArchiveError.missingVolume(let name) = $0 else { return XCTFail("Expected missing volume, got \($0)") }
                XCTAssertEqual(name, fixture.parts[index].lastPathComponent)
            }
        }
        let plain = try XCTUnwrap(corpus.archives.first { $0.id == "seektest" })
        for cancel in [false, true] {
            let fixture = try await Fixture(plain, corrupt: !cancel)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            if cancel {
                _ = try await fixture.service.prepareArchive(fixture.identity, password: nil)
                try fixture.service.cancel(fixture.identity)
            }
            do {
                if !cancel { _ = try await fixture.service.prepareArchive(fixture.identity, password: nil) }
                _ = try await fixture.service.commit(fixture.identity)
                XCTFail("Invalid extraction published")
            } catch {
                if cancel { XCTAssertEqual(error as? OperationContractError, .cancelled) }
            }
            try fixture.assertFailed()
        }
    }

    private struct Fixture {
        let archive: RarTestCorpus.Archive
        let root: URL
        let destination: URL
        let parts: [URL]
        let original: [Data]
        let service: ServerOperationService
        let intent: OperationIntent
        let identity: OperationRequestIdentity

        init(_ archive: RarTestCorpus.Archive, corrupt: Bool = false) async throws {
            self.archive = archive
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rar-helper-\(UUID())")
            self.root = root
            destination = root.appendingPathComponent("result")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("existing occupant".utf8).write(to: root.appendingPathComponent("keep"))
            parts = archive.parts.map { root.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent) }
            original = try archive.parts.map {
                var bytes = try Data(contentsOf: RarTestCorpus.source($0))
                if corrupt { bytes[bytes.count / 2] ^= 1 }
                return bytes
            }
            for (part, bytes) in zip(parts, original) { try bytes.write(to: part, options: .withoutOverwriting) }
            let account = OperationAccount(hostIdentity: "rar-helper", accountIdentity: "fixture-user")
            service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account, homeDirectory: root)
            let directory = try OperationDirectory(path: Data(root.path.utf8))
            let observations = try parts.map { try directory.proveFile(Data($0.lastPathComponent.utf8), progress: { _ in }) }
            intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveExtract,
                sources: parts.map { .init(account: account, path: .unix(Data($0.path.utf8))) },
                destination: .init(account: account, path: .unix(Data(destination.path.utf8))),
                sourceObservations: observations, conflict: .createNew, archiveFormat: "rar", archiveEncrypted: archive.password != nil)
            identity = .init(id: intent.id, account: account, epoch: service.journal.epoch,
                             intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }

        func assertOutput() throws {
            for expected in archive.expected {
                let relative = archive.rootName == nil ? expected.name : expected.name.split(separator: "/").dropFirst().joined(separator: "/")
                let output = relative.isEmpty ? destination : destination.appendingPathComponent(relative)
                let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                XCTAssertEqual(attributes[.type] as? FileAttributeType, expected.kind == "directory" ? .typeDirectory : .typeRegular, expected.name)
                if expected.kind != "directory" { try expected.assertBytes(Data(contentsOf: output)) }
                if expected.linkType == "HARD_LINK", let target = expected.target {
                    let targetAttributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(target).path)
                    XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, targetAttributes[.systemFileNumber] as? NSNumber)
                }
            }
        }

        func assertOriginals() throws {
            for (part, bytes) in zip(parts, original) { XCTAssertEqual(try Data(contentsOf: part), bytes) }
        }
        func assertPrivate(secret: String? = nil) throws {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("journal"), includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let bytes = try Data(contentsOf: file)
                if let secret { XCTAssertNil(bytes.range(of: Data(secret.utf8))) }
                XCTAssertNil(bytes.range(of: Data("\"password\":".utf8)))
            }
        }
        func assertFailed(secret: String? = nil, unchangedSources: Bool = true) throws {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("keep")), Data("existing occupant".utf8))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".detours-") })
            if unchangedSources { try assertOriginals() }
            try assertPrivate(secret: secret)
        }
        func cleanup() { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
    }
}
