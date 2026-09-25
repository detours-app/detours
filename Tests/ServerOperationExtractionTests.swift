import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationExtractionTests: XCTestCase {
    func testAcceptedExtractionMatchesExistingOutputAndCommitsOnce() async throws {
        let cases: [(ServerArchiveFormat, Bool)] = [(.sevenZ, false), (.sevenZ, true), (.zip, false), (.zip, true),
                                                   (.tarGz, false), (.tarBz2, false), (.tarXz, false)]
        for (format, encrypted) in cases {
            for wrapped in [false, true] {
                let fixture = try await Fixture(format: format, encrypted: encrypted, wrapped: wrapped)
                defer { fixture.cleanup() }
                print("Accepted extraction: \(format.rawValue), encrypted=\(encrypted), wrapped=\(wrapped)")
                _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
                let response = try await fixture.service.reply(to: .prepareArchive(identity: fixture.identity, password: fixture.password))
                guard case .receipt(let ready) = response else { return XCTFail("Expected extraction preparation receipt") }
                XCTAssertEqual(ready.phase, .readyToCommit)
                XCTAssertTrue(ready.contentVerified)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
                let duplicate = try await fixture.service.prepareArchive(fixture.identity, password: nil)
                XCTAssertEqual(duplicate, ready)
                let result = try await fixture.service.commit(fixture.identity)
                XCTAssertEqual(result.outcome, .committed)
                XCTAssertEqual(result.effects.count, 1)
                XCTAssertTrue(result.recovery.isEmpty)
                XCTAssertNil(result.failure)
                let directory = try OperationDirectory(path: Data(fixture.root.path.utf8))
                let actual = try directory.manifest(Data(fixture.destination.lastPathComponent.utf8), progress: { _ in })
                let expected = try directory.manifest(Data(fixture.existing.lastPathComponent.utf8), progress: { _ in })
                XCTAssertEqual(actual.proof, expected.proof)
                let prefix = wrapped ? "source/" : ""
                let file = fixture.destination.appendingPathComponent(prefix + "nested/émoji 📁.txt")
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
                XCTAssertEqual(attributes[.modificationDate] as? Date, fixture.modified)
                if [.tarGz, .tarBz2, .tarXz].contains(format) {
                    let parent = try OperationDirectory(path: Data(fixture.destination.appendingPathComponent(prefix).path.utf8))
                    let nested = try OperationDirectory(path: Data(file.deletingLastPathComponent().path.utf8))
                    XCTAssertEqual(try parent.observe(Data("hard".utf8)).identity, try nested.observe(Data(file.lastPathComponent.utf8)).identity)
                }
                try fixture.assertSourceUnchanged()
                try fixture.assertNoSavedPassword()
                try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("saved-result"))
                try Data("later occupant".utf8).write(to: fixture.destination)
                let repeated = try await fixture.service.commit(fixture.identity)
                XCTAssertEqual(repeated, result)
                XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("later occupant".utf8))
            }
        }
    }

    func testCancelledOrConflictingExtractionCannotPublish() async throws {
        for cancel in [false, true] {
            let fixture = try await Fixture()
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            _ = try await fixture.service.prepareArchive(fixture.identity, password: nil)
            if cancel { try fixture.service.cancel(fixture.identity) } else { try Data("competitor".utf8).write(to: fixture.destination) }
            do {
                _ = try await fixture.service.commit(fixture.identity)
                XCTFail("Invalid extraction published")
            } catch {
                if cancel { XCTAssertEqual(error as? OperationContractError, .cancelled) }
            }
            if cancel { XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path)) } else { XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("competitor".utf8)) }
            try fixture.assertSourceUnchanged()
        }
    }

    func testChangedArchiveOrPreparedPayloadIsRefused() async throws {
        for sourceChanged in [false, true] {
            let fixture = try await Fixture()
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            if sourceChanged { try Data("changed archive".utf8).write(to: fixture.archive) }
            do {
                let ready = try await fixture.service.prepareArchive(fixture.identity, password: nil)
                if sourceChanged { XCTFail("Changed archive prepared") }
                guard let location = ready.preparedPayload?.location, case .unix(let bytes) = location.path,
                      let path = String(data: bytes, encoding: .utf8) else { return XCTFail("Missing prepared payload") }
                try Data("changed payload".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("nested/émoji 📁.txt"))
                _ = try await fixture.service.commit(fixture.identity)
                XCTFail("Changed extraction published")
            } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
            if !sourceChanged { try fixture.assertSourceUnchanged() }
        }
    }

    func testWrongPasswordLeavesNoPublishedOutputOrOwnedScratch() async throws {
        for format in [ServerArchiveFormat.sevenZ, .zip] {
            let fixture = try await Fixture(format: format, encrypted: true)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            do {
                _ = try await fixture.service.prepareArchive(fixture.identity, password: "wrong password")
                XCTFail("Wrong password accepted")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
                XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
            }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".detours-partial-") })
            try fixture.assertSourceUnchanged()
            try fixture.assertNoSavedPassword()
        }
    }

    private struct Fixture {
        let root: URL
        let archive: URL
        let destination: URL
        let existing: URL
        let service: ServerOperationService
        let intent: OperationIntent
        let identity: OperationRequestIdentity
        let original: OperationManifest
        let password: String?
        let modified = Date(timeIntervalSince1970: 1_600_000_000)

        init(format: ServerArchiveFormat = .sevenZ, encrypted: Bool = false, wrapped: Bool = false) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            destination = root.appendingPathComponent("accepted-output")
            password = encrypted ? "transient extraction password" : nil
            let folder = root.appendingPathComponent("source")
            let file = folder.appendingPathComponent("nested/émoji 📁.txt")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: false)
            try Data(repeating: 42, count: 131_073).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: modified], ofItemAtPath: file.path)
            try FileManager.default.linkItem(at: file, to: folder.appendingPathComponent("hard"))
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "nested/émoji 📁.txt")
            var sources = [folder.path]
            if wrapped {
                let extra = root.appendingPathComponent("extra")
                try Data("extra file".utf8).write(to: extra)
                sources.append(extra.path)
            }
            archive = URL(fileURLWithPath: try ArchiveOperations().createArchive(items: sources, format: format.rawValue,
                                                                                archiveName: "fixture", password: password))
            existing = URL(fileURLWithPath: try ArchiveOperations().extractArchive(archive: archive.path, password: password))
            let account = OperationAccount(hostIdentity: "fixture", accountIdentity: "fixture-user")
            service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account, homeDirectory: root)
            let directory = try OperationDirectory(path: Data(root.path.utf8))
            original = try directory.manifest(Data(archive.lastPathComponent.utf8), progress: { _ in })
            let observed = try XCTUnwrap(original.entries.first?.observation)
            intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveExtract,
                                     sources: [.init(account: account, path: .unix(Data(archive.path.utf8)))],
                                     destination: .init(account: account, path: .unix(Data(destination.path.utf8))),
                                     sourceObservations: [observed], conflict: .createNew, archiveFormat: format.rawValue, archiveEncrypted: encrypted)
            identity = .init(id: intent.id, account: account, epoch: service.journal.epoch,
                             intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }

        func assertSourceUnchanged() throws {
            let directory = try OperationDirectory(path: Data(root.path.utf8))
            XCTAssertEqual(try directory.manifest(Data(archive.lastPathComponent.utf8), progress: { _ in }), original)
        }

        func assertNoSavedPassword() throws {
            guard let password else { return }
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("journal"), includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                XCTAssertNil(try Data(contentsOf: file).range(of: Data(password.utf8)), file.lastPathComponent)
            }
        }

        func cleanup() { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
    }
}
