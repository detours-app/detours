import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedMutationCallerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testRenameRecordsTheActualChangedIdentity() async throws { try await run(.rename) }
    func testCompetingRenameDestinationPreservesBothFiles() async throws { try await run(.competingName) }
    func testDeniedDestinationLookupNeverAcceptsRename() async throws { try await run(.denied) }
    func testLostRenameReplyReconcilesWithoutRepeatingMove() async throws { try await run(.lostReply) }
    func testCreateFolderKeepsAnExistingNameAndRecordsNewFolder() async throws { try await run(.folder) }

    func testCreateFileKeepsExistingNameAndCommitsVerifiedBytes() async throws { try await createFile(compete: false) }
    func testCreateFileRefusesACompetingFinalName() async throws { try await createFile(compete: true) }

    private func createFile(compete: Bool) async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let service = fixture.boundary.service
        let target = fixture.root.appendingPathComponent("source 2")
        let bytes = Data("new file contents".utf8)
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            if compete, case .commit = request { try Data("competing writer".utf8).write(to: target) }
            return try await service.reply(to: request)
        }, upload: { url, identity in try await service.prepareUpload(identity, contents: Data(contentsOf: url)) })
        let queue = FileOperationQueue.shared
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { host in
            guard host == fixture.hostID else { throw OperationContractError.identityMismatch }
            return endpoint
        }
        do {
            let result = try await queue.createFile(in: .remote(hostID: fixture.hostID, path: fixture.root.path), name: "source", content: bytes)
            XCTAssertEqual(result, .remote(hostID: fixture.hostID, path: target.path))
            if compete { XCTFail("Replaced a competing file") }
        } catch { if !compete { throw error } }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: target), compete ? Data("competing writer".utf8) : bytes)
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        XCTAssertEqual(result.items.map(\.outcome), [compete ? .failedUnchanged : .committed])
        if !compete { XCTAssertEqual(result.items.first?.result.receipt?.contentVerified, true) }
    }

    private enum Scenario: Sendable { case rename, competingName, denied, lostReply, folder }

    private func run(_ scenario: Scenario) async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let service = fixture.boundary.service
        let target = fixture.root.appendingPathComponent("renamed")
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            if scenario == .denied, case .lookup(let location) = request,
               location.path == .unix(Data(target.path.utf8)) { return .lookup(.denied) }
            if scenario == .competingName, case .execute = request {
                try Data("competing writer".utf8).write(to: target)
            }
            let reply = try await service.reply(to: request)
            if scenario == .lostReply, case .execute = request { throw OperationContractError.invalidReceipt }
            return reply
        }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let queue = FileOperationQueue.shared
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { host in
            guard host == fixture.hostID else { throw OperationContractError.identityMismatch }
            return endpoint
        }
        let original = try OperationDirectory(path: Data(fixture.root.path.utf8)).observe(Data("source".utf8))
        if scenario == .folder {
            let created = try await queue.createFolder(in: .remote(hostID: fixture.hostID, path: fixture.root.path), name: "source")
            XCTAssertEqual(created, .remote(hostID: fixture.hostID, path: fixture.root.appendingPathComponent("source 2").path))
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
            XCTAssertEqual(result.items.map(\.outcome), [.committed])
            let effect = try XCTUnwrap(result.items.first?.result.receipt?.effects.first)
            XCTAssertEqual(effect.observation.kind, .directory)
            XCTAssertEqual(effect.observation.identity,
                try OperationDirectory(path: Data(fixture.root.path.utf8)).observe(Data("source 2".utf8)).identity)
            return
        }
        do {
            let renamed = try await queue.rename(item: .remote(hostID: fixture.hostID, path: fixture.source.path), to: "renamed")
            XCTAssertEqual(renamed, .remote(hostID: fixture.hostID, path: target.path))
            if scenario == .competingName || scenario == .denied { XCTFail("Unsafe rename succeeded") }
        } catch {
            if scenario == .rename || scenario == .lostReply { throw error }
        }
        if scenario == .denied {
            XCTAssertTrue(queue.remoteOperationResults.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        } else {
            let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
            if scenario == .competingName {
                XCTAssertEqual(result.items.map(\.outcome), [.failedUnchanged])
                XCTAssertEqual(try Data(contentsOf: target), Data("competing writer".utf8))
                XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            } else {
                XCTAssertEqual(result.items.map(\.outcome), [.committed])
                XCTAssertEqual(result.items.first?.result.receipt?.effects.first?.observation.identity, original.identity)
                XCTAssertEqual(try Data(contentsOf: target), fixture.bytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
            }
        }
    }
}
