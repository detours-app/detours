import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedExtractionCallerTests: XCTestCase {
    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testSingleItemNamesAndWrappersMatchAllExistingFormats() async throws {
        for format in ArchiveFormat.allCases {
            try await run(format: format, scenario: .single)
            try await run(format: format, scenario: .multiple)
        }
    }

    func testEncryptedExtractionRequestsPasswordAndRetainsRetry() async throws {
        for format in [ArchiveFormat.zip, .sevenZ] { try await run(format: format, scenario: .encrypted) }
    }

    func testCompetingExtractionNamePreservesArchiveAndOccupant() async throws { try await run(format: .zip, scenario: .compete) }
    func testChangedArchiveAfterInspectionCannotBeExtracted() async throws { try await run(format: .zip, scenario: .changed) }

    private enum Scenario: Sendable { case single, multiple, encrypted, compete, changed }

    private func run(format: ArchiveFormat, scenario: Scenario) async throws {
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("notes.txt")
        try fixture.bytes.write(to: source)
        let folder = fixture.root.appendingPathComponent("empty folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let password = scenario == .encrypted ? "fixture secret" : nil
        let sources = scenario == .multiple ? [source.path, folder.path] : [source.path]
        let archive = URL(fileURLWithPath: try ArchiveOperations().createArchive(items: sources, format: format.rawValue,
            archiveName: "different name", password: password))
        let expected = fixture.root.appendingPathComponent(scenario == .multiple ? "different name" : "notes.txt 2")
        let archiveBytes = try Data(contentsOf: archive)
        let service = fixture.boundary.service
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            if scenario == .compete, case .commit = request { try Data("competing writer".utf8).write(to: expected) }
            let reply = try await service.reply(to: request)
            if scenario == .changed, case .archiveLayout = request { try Data("changed archive".utf8).write(to: archive) }
            return reply
        }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { host in
            guard host == fixture.hostID else { throw OperationContractError.identityMismatch }
            return endpoint
        }
        let location = Location.remote(hostID: fixture.hostID, path: archive.path)
        if scenario == .encrypted {
            for supplied in [nil, "wrong fixture password"] as [String?] {
                do {
                    _ = try await queue.extract(archive: location, password: supplied)
                    XCTFail("Encrypted archive accepted an absent or wrong password")
                } catch FileOperationError.archivePasswordRequired {}
                XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
                XCTAssertEqual(try Data(contentsOf: archive), archiveBytes)
            }
        }
        do {
            let extracted = try await queue.extract(archive: location, password: password)
            XCTAssertEqual(extracted, .remote(hostID: fixture.hostID, path: expected.path))
            if scenario == .compete || scenario == .changed { XCTFail("Unsafe extraction succeeded") }
        } catch { if scenario != .compete && scenario != .changed { throw error } }
        XCTAssertEqual(try Data(contentsOf: source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: archive), scenario == .changed ? Data("changed archive".utf8) : archiveBytes)
        if scenario == .changed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
        } else if scenario == .compete {
            XCTAssertEqual(try Data(contentsOf: expected), Data("competing writer".utf8))
        } else {
            XCTAssertEqual(try Data(contentsOf: scenario == .multiple ? expected.appendingPathComponent("notes.txt") : expected), fixture.bytes)
            if scenario == .multiple { XCTAssertTrue(FileManager.default.fileExists(atPath: expected.appendingPathComponent("empty folder").path)) }
            XCTAssertTrue(queue.remoteOperationResults.values.contains { $0.items.contains { $0.outcome == .committed } })
        }
    }
}
