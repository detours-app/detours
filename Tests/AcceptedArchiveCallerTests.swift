import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedArchiveCallerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testPublicArchiveCreationPreservesAllFormatsAndSelectedContents() async throws {
        for format in ArchiveFormat.allCases { try await run(format: format) }
    }

    func testPublicEncryptedArchiveKeepsPasswordOutOfSavedIntent() async throws {
        for format in [ArchiveFormat.zip, .sevenZ] { try await run(format: format, password: "fixture secret") }
    }

    func testExistingArchiveNameIsPreserved() async throws { try await run(format: .tarGz, occupied: true) }
    func testCompetingArchiveNameRefusesPublication() async throws { try await run(format: .zip, compete: true) }

    private func run(format: ArchiveFormat, password: String? = nil, occupied: Bool = false, compete: Bool = false) async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let service = fixture.boundary.service
        let target = fixture.root.appendingPathComponent("bundle.\(format.fileExtension)")
        if occupied { try Data("existing archive".utf8).write(to: target) }
        let folder = fixture.root.appendingPathComponent("folder with spaces")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fixture.bytes.write(to: folder.appendingPathComponent("é child"))
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            if compete, case .commit = request { try Data("competing writer".utf8).write(to: target) }
            return try await service.reply(to: request)
        }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let queue = FileOperationQueue.shared
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { host in
            guard host == fixture.hostID else { throw OperationContractError.identityMismatch }
            return endpoint
        }
        var archived: Location?
        do {
            archived = try await queue.archive(items: [fixture.source, folder].map { .remote(hostID: fixture.hostID, path: $0.path) },
                format: format, archiveName: "bundle", password: password)
            if compete { XCTFail("Competing archive was overwritten") }
        } catch { if !compete { throw error } }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("é child")), fixture.bytes)
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        XCTAssertEqual(result.items.map(\.outcome), compete ? [.failedUnchanged] : [.committed])
        if compete {
            XCTAssertEqual(try Data(contentsOf: target), Data("competing writer".utf8))
            return
        }
        let archive = try XCTUnwrap(archived)
        XCTAssertEqual(archive.lastPathComponent, "bundle\(occupied ? " 2" : "").\(format.fileExtension)")
        if occupied { XCTAssertEqual(try Data(contentsOf: target), Data("existing archive".utf8)) }
        let extracted = URL(fileURLWithPath: try ArchiveOperations().extractArchive(archive: archive.path, password: password))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("source")), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("folder with spaces/é child")), fixture.bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("folder with spaces/empty").path))
        let recorded = try JSONEncoder().encode(result)
        if let password { XCTAssertFalse(try XCTUnwrap(String(data: recorded, encoding: .utf8)).contains(password)) }
        XCTAssertEqual(result.items.first?.result.intent.action, .archiveCreate)
        XCTAssertEqual(result.items.first?.result.intent.archiveEncrypted, password != nil)
    }
}
