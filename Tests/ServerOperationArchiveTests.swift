import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationArchiveTests: XCTestCase {
    func testAcceptedArchivePreparesPrivatelyAndCommitsOnceWithoutPersistingPassword() async throws {
        for (format, encrypted) in [(ServerArchiveFormat.sevenZ, false), (.sevenZ, true), (.zip, false), (.zip, true)] {
            let fixture = try await Fixture(encrypted: encrypted, overlap: true, format: format)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let response = try await fixture.service.reply(to: .prepareArchive(identity: fixture.identity, password: fixture.password))
            guard case .receipt(let ready) = response else { return XCTFail("Expected prepared archive receipt") }
            XCTAssertEqual(ready.phase, .readyToCommit)
            XCTAssertTrue(ready.contentVerified)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            let snapshot = try fixture.service.status(fixture.identity)
            XCTAssertEqual(try snapshot.sourceManifest?.entries.map { try XCTUnwrap(String(data: $0.relativePath, encoding: .utf8)) },
                           ["first", "first/empty", "first/link", "first/nested", "first/nested/émoji 📁.txt", "second/notes"])
            XCTAssertEqual(snapshot.payloadManifest?.entries.first?.observation, ready.preparedPayload?.observation)
            try fixture.assertSourcesUnchanged()
            let duplicate = try await fixture.service.prepareArchive(fixture.identity, password: nil)
            XCTAssertEqual(duplicate, ready)
            let committed = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(committed.outcome, .committed)
            XCTAssertEqual(committed.effects.count, 1)
            XCTAssertEqual(committed.effects.first?.observation.identity, ready.preparedPayload?.observation.identity)
            XCTAssertTrue(committed.recovery.isEmpty)
            XCTAssertNil(committed.failure)
            if format == .zip { try assertZIPHeaders(fixture.destination, encrypted: encrypted) }
            print("Archive compatibility: \(format.rawValue), encrypted=\(encrypted), prepared output extraction")
            let extracted = URL(fileURLWithPath: try ArchiveOperations().extractArchive(archive: fixture.destination.path, password: fixture.password))
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("first/nested/émoji 📁.txt")), fixture.contents)
            let notes = format == .sevenZ ? "notes" : "second/notes"
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(notes)), Data("second file".utf8))
            if format == .sevenZ {
                XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("émoji 📁.txt")), fixture.contents)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extracted.appendingPathComponent("first/empty").path), [])
            let link = extracted.appendingPathComponent("first/link")
            XCTAssertEqual(try Data(contentsOf: link), fixture.contents)
            XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
            XCTAssertEqual(snapshot.archiveInputManifest?.entries.first { $0.relativePath == Data("first/link".utf8) }?.observation.kind, .file)
            let legacy = try ArchiveOperations().createArchive(items: fixture.originals.map { $0.0.path }, format: format.rawValue,
                                                               archiveName: "legacy", password: fixture.password)
            print("Archive compatibility: \(format.rawValue), encrypted=\(encrypted), existing output extraction")
            let legacyExtracted = URL(fileURLWithPath: try ArchiveOperations().extractArchive(archive: legacy, password: fixture.password))
            let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
            XCTAssertEqual(try parent.manifest(Data(extracted.lastPathComponent.utf8), progress: { _ in }).proof,
                           try parent.manifest(Data(legacyExtracted.lastPathComponent.utf8), progress: { _ in }).proof)
            let attributes = try FileManager.default.attributesOfItem(atPath: extracted.appendingPathComponent("first/nested/émoji 📁.txt").path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            XCTAssertEqual(attributes[.modificationDate] as? Date, fixture.modified)
            if encrypted {
                XCTAssertThrowsError(try ArchiveOperations().extractArchive(archive: fixture.destination.path, password: "wrong fixture password")) {
                    XCTAssertEqual($0 as? ArchiveOperationsError, .wrongPassword)
                }
            }
            try fixture.assertSourcesUnchanged()
            try fixture.assertNoSavedPassword()
            try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("saved.7z"))
            try Data("later occupant".utf8).write(to: fixture.destination)
            let repeated = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(repeated, committed)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("later occupant".utf8))
        }
    }

    func testReplacementRetainsOriginalAndRechecksApprovedVersion() async throws {
        for changed in [false, true] {
            let fixture = try await Fixture(replace: true)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            _ = try await fixture.service.prepareArchive(fixture.identity, password: nil)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("original destination".utf8))
            if changed {
                try Data("later destination".utf8).write(to: fixture.destination)
                do {
                    _ = try await fixture.service.commit(fixture.identity)
                    XCTFail("Changed replacement was published")
                } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
                XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("later destination".utf8))
            } else {
                let result = try await fixture.service.commit(fixture.identity)
                XCTAssertEqual(result.outcome, .committed)
                let original = try XCTUnwrap(result.recovery.first { $0.purpose == .displacedOriginal })
                let saved = try fixture.url(XCTUnwrap(original.knownLocation))
                XCTAssertEqual(try Data(contentsOf: saved), Data("original destination".utf8))
                _ = try ArchiveOperations().extractArchive(archive: fixture.destination.path, password: nil)
            }
            try fixture.assertSourcesUnchanged()
        }
    }

    func testChangedSourceAndOccupiedDestinationFailBeforeAllocation() async throws {
        for sourceChanged in [false, true] {
            let fixture = try await Fixture()
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            if sourceChanged {
                try Data("changed source".utf8).write(to: fixture.file)
            } else { try Data("competitor".utf8).write(to: fixture.destination) }
            do {
                _ = try await fixture.service.prepareArchive(fixture.identity, password: nil)
                XCTFail("Invalid archive preparation succeeded")
            } catch {
                if sourceChanged { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
            }
            let result = try fixture.service.status(fixture.identity)
            XCTAssertNil(result.workspace)
            XCTAssertEqual(result.receipt?.outcome, .failedUnchanged)
            if sourceChanged {
                XCTAssertEqual(try Data(contentsOf: fixture.file), Data("changed source".utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("competitor".utf8))
                try fixture.assertSourcesUnchanged()
            }
            let duplicate = try await fixture.service.prepareArchive(fixture.identity, password: nil)
            XCTAssertEqual(duplicate, result.receipt)
        }
    }

    func testCancelledAndCompetingPublicationPreserveSources() async throws {
        for cancel in [false, true] {
            let fixture = try await Fixture()
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            _ = try await fixture.service.prepareArchive(fixture.identity, password: nil)
            if cancel {
                try fixture.service.cancel(fixture.identity)
            } else { try Data("competitor".utf8).write(to: fixture.destination) }
            do {
                _ = try await fixture.service.commit(fixture.identity)
                XCTFail("Invalid archive publication succeeded")
            } catch {
                if cancel { XCTAssertEqual(error as? OperationContractError, .cancelled) }
            }
            try fixture.assertSourcesUnchanged()
            if cancel {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            } else { XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("competitor".utf8)) }
        }
    }

    func testModifiedOrSubstitutedPreparedArchiveCannotBePublished() async throws {
        for substitute in [false, true] {
            let fixture = try await Fixture()
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let ready = try await fixture.service.prepareArchive(fixture.identity, password: nil)
            let payload = try fixture.url(XCTUnwrap(ready.preparedPayload).location)
            if substitute { try FileManager.default.moveItem(at: payload, to: fixture.root.appendingPathComponent("saved")) }
            try Data("other writer".utf8).write(to: payload)
            do {
                _ = try await fixture.service.commit(fixture.identity)
                XCTFail("Changed archive was published")
            } catch { XCTAssertEqual(error as? OperationFilesystemError, .identityChanged) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            try fixture.assertSourcesUnchanged()
            let result = try fixture.service.status(fixture.identity)
            XCTAssertEqual(result.receipt?.outcome, substitute ? .partial : .failedUnchanged)
            if substitute { XCTAssertEqual(try Data(contentsOf: payload), Data("other writer".utf8)) }
        }
    }

    func testEncryptedIntentCannotSilentlyBecomePlainArchive() async throws {
        for encrypted in [false, true] {
            let fixture = try await Fixture(encrypted: encrypted)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            do {
                _ = try await fixture.service.prepareArchive(fixture.identity, password: encrypted ? nil : "unapproved fixture password")
                XCTFail("Changed encryption intent was accepted")
            } catch { XCTAssertEqual(error as? OperationContractError, .intentMismatch) }
            XCTAssertNil(try fixture.service.status(fixture.identity).workspace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            try fixture.assertSourcesUnchanged()
        }
    }

    func testArchiveInsideSelectedSourceIsRefusedBeforeTemporaryFiles() async throws {
        let fixture = try await Fixture(inside: true)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        do {
            _ = try await fixture.service.prepareArchive(fixture.identity, password: nil)
            XCTFail("Archive preparation changed its selected source")
        } catch { XCTAssertEqual(error as? OperationFilesystemError, .unsupported) }
        XCTAssertNil(try fixture.service.status(fixture.identity).workspace)
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
        try fixture.assertSourcesUnchanged()
    }

    private func assertZIPHeaders(_ archive: URL, encrypted: Bool) throws {
        let bytes = [UInt8](try Data(contentsOf: archive))
        func integer(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= bytes.count else { throw OperationFilesystemError.invalidPath }
            return (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << (8 * $1)) }
        }
        let end = try XCTUnwrap((0...max(0, bytes.count - 22)).reversed().first { offset in
            Array(bytes[offset..<min(offset + 4, bytes.count)]) == [0x50, 0x4b, 0x05, 0x06]
        })
        var central = try integer(end + 16, 4)
        for _ in 0..<(try integer(end + 10, 2)) {
            XCTAssertEqual(try integer(central, 4), 0x02014b50)
            let local = try integer(central + 42, 4)
            XCTAssertEqual(try integer(local, 4), 0x04034b50)
            let length = try integer(central + 28, 2)
            let localLength = try integer(local + 26, 2)
            let name = Array(bytes[(central + 46)..<(central + 46 + length)])
            let localName = Array(bytes[(local + 30)..<(local + 30 + localLength)])
            XCTAssertEqual(localName, name)
            let flags = try integer(central + 8, 2)
            XCTAssertEqual(try integer(local + 6, 2), flags, try XCTUnwrap(String(bytes: name, encoding: .utf8)))
            if name.contains(where: { $0 >= 128 }) { XCTAssertNotEqual(flags & 0x800, 0) }
            if encrypted, name.last != 47 {
                XCTAssertEqual(try integer(central + 10, 2), 99)
                var extra = central + 46 + length
                let limit = extra + (try integer(central + 30, 2))
                var foundAES = false
                while extra + 4 <= limit {
                    let size = try integer(extra + 2, 2)
                    if try integer(extra, 2) == 0x9901 {
                        XCTAssertEqual(size, 7)
                        XCTAssertEqual(try integer(extra + 8, 1), 3)
                        foundAES = true
                    }
                    extra += 4 + size
                }
                XCTAssertTrue(foundAES)
            }
            central += 46 + length + (try integer(central + 30, 2)) + (try integer(central + 32, 2))
        }
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let destination: URL
        let service: ServerOperationService
        let intent: OperationIntent
        let identity: OperationRequestIdentity
        let originals: [(URL, OperationManifest)]
        let password: String?
        let contents = Data(repeating: 42, count: 131_073)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)

        init(encrypted: Bool = false, overlap: Bool = false, replace: Bool = false, inside: Bool = false,
             format: ServerArchiveFormat = .sevenZ) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            file = root.appendingPathComponent("first/nested/émoji 📁.txt")
            destination = root.appendingPathComponent((inside ? "first/result." : "result.") + format.fileExtension)
            password = encrypted ? "transient fixture secret 🗝" : nil
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("first/empty"), withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("second"), withIntermediateDirectories: false)
            try contents.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: modified], ofItemAtPath: file.path)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("first/link").path, withDestinationPath: "nested/émoji 📁.txt")
            try Data("second file".utf8).write(to: root.appendingPathComponent("second/notes"))
            if replace { try Data("original destination".utf8).write(to: destination) }
            let account = OperationAccount(hostIdentity: "fixture", accountIdentity: "fixture-user")
            service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account, homeDirectory: root)
            var sources = [root.appendingPathComponent("first"), root.appendingPathComponent("second/notes")]
            if overlap { sources.append(file) }
            originals = try sources.map { source in
                let parent = try OperationDirectory(path: Data(source.deletingLastPathComponent().path.utf8))
                return (source, try parent.manifest(Data(source.lastPathComponent.utf8), progress: { _ in }))
            }
            let observations = try sources.map { source in
                try OperationDirectory(path: Data(source.deletingLastPathComponent().path.utf8))
                    .proveObject(Data(source.lastPathComponent.utf8), progress: { _ in })
            }
            let conflict: OperationIntent.Conflict
            if replace {
                conflict = .replace(try OperationDirectory(path: Data(root.path.utf8)).observe(Data(destination.lastPathComponent.utf8)))
            } else { conflict = .createNew }
            intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveCreate,
                                     sources: sources.map { .init(account: account, path: .unix(Data($0.path.utf8))) },
                                     destination: .init(account: account, path: .unix(Data(destination.path.utf8))),
                                     sourceObservations: observations, conflict: conflict, archiveFormat: format.rawValue, archiveEncrypted: encrypted)
            identity = OperationRequestIdentity(id: intent.id, account: account, epoch: service.journal.epoch,
                                                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }

        func assertSourcesUnchanged() throws {
            for (source, original) in originals {
                let parent = try OperationDirectory(path: Data(source.deletingLastPathComponent().path.utf8))
                XCTAssertEqual(try parent.manifest(Data(source.lastPathComponent.utf8), progress: { _ in }), original)
            }
        }

        func assertNoSavedPassword() throws {
            guard let password else { return }
            let journal = root.appendingPathComponent("journal")
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: journal, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    XCTAssertNil(try Data(contentsOf: file).range(of: Data(password.utf8)), file.lastPathComponent)
                }
            }
        }

        func url(_ location: OperationLocation) throws -> URL {
            guard case .unix(let bytes) = location.path else { throw OperationFilesystemError.invalidPath }
            return URL(fileURLWithPath: try XCTUnwrap(String(data: bytes, encoding: .utf8)))
        }

        func cleanup() { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
    }
}
