import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedCrossHostFileTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testMoveAcrossAccountsPublishesBeforeIndependentSourceTrash() async throws {
        try await run(.success)
    }

    func testPublicQueueMoveAcrossHostsUsesRecordedUploadAndSourceTrash() async throws {
        try await run(.queueSuccess)
    }

    func testChangedStagedBytesCannotPublishOrTrashSource() async throws {
        try await run(.changedPayload)
    }

    func testChangedSourceAfterDestinationCommitRetainsBothCopies() async throws {
        try await run(.changedSource)
    }

    func testLostSourceTrashReplyRetainsDestinationAndDoesNotReplay() async throws {
        try await run(.lostTrashReply)
    }

    private enum Scenario: Sendable { case success, queueSuccess, changedPayload, changedSource, lostTrashReply }

    private func run(_ scenario: Scenario) async throws {
        let source = try await CoordinatorFixture(account: .init(hostIdentity: "source-host", accountIdentity: "source-account"))
        let destination = try await CoordinatorFixture(account: .init(hostIdentity: "destination-host", accountIdentity: "destination-account"))
        defer { source.cleanup(); destination.cleanup() }
        let queue = FileOperationQueue.shared
        let sourceEndpoint = endpoint(source, store: source.store, scenario: scenario, source: source, isDestination: false)
        let destinationEndpoint = endpoint(destination, store: source.store, scenario: scenario, source: source, isDestination: true)
        for (fixture, endpoint) in [(source, sourceEndpoint), (destination, destinationEndpoint)] {
            let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: fixture.boundary.service),
                transferChannel: RemoteTransferChannel(sshTarget: "unused"))
            queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        }
        let coordinator = RemoteOperationCoordinator(store: source.store) { host in
            if host == source.hostID { return sourceEndpoint }
            if host == destination.hostID { return destinationEndpoint }
            throw OperationContractError.identityMismatch
        }
        queue.acceptedCoordinator = coordinator
        let operation = try await coordinator.create()
        var plan = RemoteTransferPlan(hostID: destination.hostID, operation: operation, mergeDirectories: false)
        let targetDirectory = destination.root.appendingPathComponent("output")
        let staging = source.root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        if scenario == .queueSuccess {
            let moved = try await queue.move(items: [.remote(hostID: source.hostID, path: source.source.path)],
                to: .remote(hostID: destination.hostID, path: targetDirectory.path))
            XCTAssertEqual(moved, [.remote(hostID: destination.hostID, path: targetDirectory.appendingPathComponent("source").path)])
            let saved = try XCTUnwrap(queue.remoteOperationResults.values.first)
            XCTAssertEqual(saved.items.map(\.outcome), [.committed, .committed])
            XCTAssertEqual(saved.items.map(\.hostID), [destination.hostID, source.hostID])
            let originals = try await queue.acceptedLocations(saved, sources: true)
            XCTAssertEqual(originals, [.remote(hostID: source.hostID, path: source.source.path)])
            XCTAssertEqual(try Data(contentsOf: targetDirectory.appendingPathComponent("source")), source.bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.source.path))
            await source.session.disconnect()
            await destination.session.disconnect()
            return
        }
        try await queue.planCrossHostFile(.remote(hostID: source.hostID, path: source.source.path),
            directory: .unix(Data(targetDirectory.path.utf8)), isMove: true, stagingDirectory: staging, plan: &plan)
        XCTAssertEqual(plan.items.map(\.hostID), [destination.hostID, source.hostID])
        XCTAssertEqual(plan.items[0].intent.sources.first?.account, source.account)
        XCTAssertEqual(plan.items[0].intent.destination?.account, destination.account)
        if scenario == .changedPayload {
            guard case .upload(let staged) = plan.items[0].work else { return XCTFail("Missing staged upload") }
            try Data("changed staged bytes".utf8).write(to: staged)
        }
        let result = try await coordinator.performBatch(plan.items, operation: operation, selections: plan.selections)
        let target = targetDirectory.appendingPathComponent("source")
        switch scenario {
        case .success, .queueSuccess:
            XCTAssertEqual(result.items.map(\.outcome), [.committed, .committed])
            XCTAssertEqual(try Data(contentsOf: target), source.bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.source.path))
            XCTAssertTrue(result.items[1].result.receipt?.recovery.contains { $0.purpose == .sourceTrash } == true)
        case .changedPayload:
            XCTAssertEqual(result.items.map(\.outcome), [.failedUnchanged, .notStarted])
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: source.source), source.bytes)
        case .changedSource:
            XCTAssertEqual(result.items.map(\.outcome), [.committed, .failedUnchanged])
            XCTAssertEqual(try Data(contentsOf: target), source.bytes)
            XCTAssertEqual(try Data(contentsOf: source.source), Data("new source bytes".utf8))
        case .lostTrashReply:
            XCTAssertEqual(result.items.map(\.outcome), [.committed, .unknown])
            XCTAssertEqual(try Data(contentsOf: target), source.bytes)
            let repeated = try await coordinator.performBatch(plan.items, operation: operation, selections: plan.selections)
            XCTAssertEqual(repeated, result)
        }
        await source.session.disconnect()
        await destination.session.disconnect()
    }

    private func endpoint(_ fixture: CoordinatorFixture, store: RemoteOperationStore, scenario: Scenario,
                          source: CoordinatorFixture, isDestination: Bool) -> RemoteOperationCoordinator.Endpoint {
        let service = fixture.boundary.service
        return .init(session: fixture.session, request: { request in
            if case .accept(let identity, _) = request {
                let saved = try store.load(identity.id.operation)
                guard saved.items.count == 2, saved.items.last?.requiresVerified == [saved.items[0].identity.id],
                      saved.selections?.count == 1 else { throw OperationContractError.invalidReceipt }
            }
            if !isDestination, scenario == .lostTrashReply, case .status = request { throw OperationContractError.invalidReceipt }
            let reply = try await service.reply(to: request)
            if isDestination, scenario == .changedSource, case .commit = request {
                try Data("new source bytes".utf8).write(to: source.source)
            }
            if !isDestination, scenario == .lostTrashReply, case .execute = request { throw OperationContractError.invalidReceipt }
            return reply
        }, upload: { url, identity in
            guard case .receipt(let receipt) = try await service.reply(to: .prepareUpload(identity: identity, contents: Data(contentsOf: url))) else {
                throw OperationContractError.invalidReceipt
            }
            return receipt
        })
    }
}
