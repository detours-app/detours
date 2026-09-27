import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedCrossHostTreeTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testCompleteFolderMovesAfterVerifiedPublication() async throws { try await run(.success) }
    func testBrokenNestedLinkPublishesPartialAndRetainsWholeSource() async throws { try await run(.omittedLink) }
    func testOrdinaryChildReadFailurePublishesNothing() async throws { try await run(.readFailure) }
    func testChangedSourceAfterFolderCommitRetainsBothCopies() async throws { try await run(.changedSource) }
    func testSelectedLinkMoveCopiesReferentAndTrashesOnlyOriginalLink() async throws { try await run(.selectedLink) }

    private enum Scenario: Sendable { case success, omittedLink, readFailure, changedSource, selectedLink }

    private func run(_ scenario: Scenario) async throws {
        let source = try await CoordinatorFixture(account: .init(hostIdentity: "tree-source", accountIdentity: "tree-source"))
        let destination = try await CoordinatorFixture(account: .init(hostIdentity: "tree-destination", accountIdentity: "tree-destination"))
        defer { source.cleanup(); destination.cleanup() }
        let folder = source.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("first child".utf8).write(to: folder.appendingPathComponent("a child"))
        let later = folder.appendingPathComponent("z child")
        try Data("later child".utf8).write(to: later)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("relative").path, withDestinationPath: "a child")
        if scenario == .omittedLink {
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("missing link").path,
                                                     withDestinationPath: "does-not-exist")
        }
        var selected = folder
        if scenario == .selectedLink {
            selected = source.root.appendingPathComponent("selected link")
            try FileManager.default.createSymbolicLink(atPath: selected.path, withDestinationPath: "folder")
        }
        let queue = FileOperationQueue.shared
        for fixture in [source, destination] {
            let service = fixture.boundary.service
            let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
                let reply = try await service.reply(to: request)
                if fixture.hostID == destination.hostID, scenario == .changedSource, case .commit = request {
                    try Data("changed source".utf8).write(to: later)
                }
                return reply
            }, upload: { url, identity in
                try await service.prepareUpload(identity, contents: Data(contentsOf: url))
            })
            let rpc = TreeReadBoundary(service: service, unreadable: scenario == .readFailure && fixture.hostID == source.hostID ? later.path : nil)
            let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: rpc,
                                              transferChannel: RemoteTransferChannel(sshTarget: "unused"))
            queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        }
        let coordinator = RemoteOperationCoordinator(store: source.store) { host in
            try await MainActor.run {
                guard let endpoint = queue.remoteOperationEndpoints[host] else { throw OperationContractError.identityMismatch }
                return endpoint
            }
        }
        queue.acceptedCoordinator = coordinator
        let output = destination.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let target = output.appendingPathComponent(selected.lastPathComponent)
        do {
            _ = try await queue.move(items: [.remote(hostID: source.hostID, path: selected.path)],
                                     to: .remote(hostID: destination.hostID, path: output.path))
            if [.omittedLink, .readFailure, .changedSource].contains(scenario) { XCTFail("Incomplete move reported success") }
        } catch {
            if scenario == .success || scenario == .selectedLink { throw error }
        }
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        if scenario == .readFailure {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertTrue(result.items.allSatisfy { $0.sent.isEmpty })
            XCTAssertEqual(try Data(contentsOf: later), Data("later child".utf8))
        } else {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("z child")), Data("later child".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("empty").path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("relative").path), "a child")
            XCTAssertTrue(result.items[0].sent.contains(.expandUpload))
            switch scenario {
            case .success, .selectedLink:
                XCTAssertEqual(result.items.map(\.outcome), [.committed, .committed])
                XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
                if scenario == .selectedLink {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
                    XCTAssertEqual(result.items[1].result.intent.sourceObservations.first?.kind, .symbolicLink)
                    XCTAssertEqual(result.items[1].result.intent.sourceManifest?.entries.first?.observation.kind, .symbolicLink)
                }
            case .omittedLink:
                XCTAssertEqual(result.items.map(\.outcome), [.committed, .failedUnchanged, .notStarted])
                XCTAssertEqual(result.items[1].preflightFailure, .linkTargetMissing)
                XCTAssertEqual(result.items[1].result.intent.sources.first?.path, .unix(Data(folder.appendingPathComponent("missing link").path.utf8)))
                XCTAssertEqual(result.outcome(for: try XCTUnwrap(result.selections?.first)), .partial)
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
                XCTAssertTrue(result.items[2].sent.isEmpty)
            case .changedSource:
                XCTAssertEqual(result.items.map(\.outcome), [.committed, .failedUnchanged])
                XCTAssertEqual(try Data(contentsOf: later), Data("changed source".utf8))
            case .readFailure: break
            }
        }
        await source.session.disconnect()
        await destination.session.disconnect()
    }
}

private struct TreeReadBoundary: RemoteRPCClient {
    let service: ServerOperationService
    let unreadable: String?

    func send(_ message: RPCMessage) async throws -> [Data] {
        if case .download(let path, _) = message, String(data: path.bytes, encoding: .utf8) == unreadable {
            throw FileProviderError.unsupportedOperation("Fixture child read refused.")
        }
        return try await AcceptedProviderRPC(service: service).send(message)
    }
}
