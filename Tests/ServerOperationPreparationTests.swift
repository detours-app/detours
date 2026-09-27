import Foundation
import RemoteOperationSupport
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import detours_server

final class ServerOperationPreparationTests: XCTestCase {
    func testOccupiedDestinationRejectsPreparationAndKeepsItsResult() async throws {
        for route in [Route.upload, .file, .tree] {
            let fixture = try await Fixture(route: route)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            try Data("competitor".utf8).write(to: fixture.destination)
            do {
                _ = try await fixture.prepare()
                XCTFail("Occupied destination permitted preparation")
            } catch { XCTAssertEqual(error as? OperationFilesystemError, .system(EEXIST)) }
            let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
            XCTAssertEqual(result.outcome, .failedUnchanged)
            XCTAssertNil(try fixture.service.status(fixture.identity).workspace)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("competitor".utf8))
            try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("competitor"))
            let duplicate = try await fixture.prepare()
            XCTAssertEqual(duplicate, result)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".detours-partial-") })
        }
    }

    func testDuplicatePreparationReturnsReadyAndCommittedReceiptsWithoutReadingSourceAgain() async throws {
        for route in [Route.upload, .file, .tree] {
            let fixture = try await Fixture(route: route)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let ready = try await fixture.prepare()
            if route != .upload {
                try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("source"),
                                                to: fixture.root.appendingPathComponent("saved-source"))
            }
            let duplicate = try await fixture.prepare()
            XCTAssertEqual(duplicate, ready)
            let committed = try await fixture.service.commit(fixture.identity)
            let afterCommit = try await fixture.prepare()
            XCTAssertEqual(afterCommit, committed)
            let payload = route == .tree ? fixture.destination.appendingPathComponent("file") : fixture.destination
            XCTAssertEqual(try Data(contentsOf: payload), fixture.bytes)
        }
    }

    func testCancellationBeforeAllocationHasAStableUnchangedResult() async throws {
        let fixture = try await Fixture(route: .upload)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        try fixture.service.cancel(fixture.identity)
        do {
            _ = try await fixture.prepare()
            XCTFail("Cancelled item prepared a payload")
        } catch { XCTAssertEqual(error as? OperationContractError, .cancelled) }
        let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
        XCTAssertEqual(result.outcome, .failedUnchanged)
        XCTAssertNil(try fixture.service.status(fixture.identity).workspace)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["journal"])
        let duplicate = try await fixture.prepare()
        XCTAssertEqual(duplicate, result)
    }

    private enum Route { case upload, file, tree }

    private struct Fixture {
        let root: URL
        let destination: URL
        let service: ServerOperationService
        let identity: OperationRequestIdentity
        let intent: OperationIntent
        let route: Route
        let bytes = Data("incoming".utf8)

        init(route: Route) async throws {
            self.route = route
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let account = OperationAccount(hostIdentity: "fixture", accountIdentity: "fixture-user")
            service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account, homeDirectory: root)
            var sources: [OperationLocation] = []
            var observations: [OperationObservation] = []
            if route != .upload {
                let source = root.appendingPathComponent("source")
                if route == .tree { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false) }
                try bytes.write(to: route == .tree ? source.appendingPathComponent("file") : source)
                sources = [.init(account: account, path: .unix(Data(source.path.utf8)))]
                observations = [try OperationDirectory(path: Data(root.path.utf8)).observe(Data("source".utf8))]
            }
            intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy, sources: sources,
                                     destination: .init(account: account, path: .unix(Data(destination.path.utf8))),
                                     sourceObservations: observations, conflict: .createNew,
                                     payloadProof: route == .upload ? try OperationContentProof.data(bytes) : nil)
            identity = OperationRequestIdentity(id: intent.id, account: account, epoch: service.journal.epoch,
                                                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }

        func prepare() async throws -> OperationReceipt {
            if route == .upload { return try await service.prepareUpload(identity, contents: bytes) }
            return try await service.prepareCopy(identity)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
