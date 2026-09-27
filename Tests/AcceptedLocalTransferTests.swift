import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedLocalTransferTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testRemoteFileMovePublishesLocallyBeforeSourceTrash() async throws { try await run(.incomingFile) }
    func testRemoteFolderMovePublishesLocallyWithEmptyDirectoryAndLink() async throws { try await run(.incomingFolder) }
    func testLocalFolderMoveUsesRecordedSourceTrashAfterRemoteCommit() async throws { try await run(.outgoingFolder) }
    func testCompetingLocalNamePreventsCommitAndRetainsRemoteSource() async throws { try await run(.competingName) }
    func testLostLocalSourceTrashReplyRetainsConfirmedRemoteCopy() async throws { try await run(.lostTrash) }

    func testChangedActualLocalSourceIsRestoredAndRemoteCopyRetained() async throws { try await run(.changedDuringTrash) }

    private enum Scenario: Sendable { case incomingFile, incomingFolder, outgoingFolder, competingName, lostTrash, changedDuringTrash }

    private func run(_ scenario: Scenario) async throws {
        let remote = try await CoordinatorFixture()
        defer { remote.cleanup() }
        let root = remote.root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let account = OperationAccount(hostIdentity: "local", accountIdentity: "local")
        let local = LocalTransferService(journal: try await OperationJournal(root: root.appendingPathComponent("journal"), account: account),
            afterSourceMove: { location in
                if scenario == .changedDuringTrash {
                    guard case .unix(let bytes) = location.path, let path = String(data: bytes, encoding: .utf8) else {
                        throw OperationFilesystemError.invalidPath
                    }
                    try Data("changed original".utf8).write(to: URL(fileURLWithPath: path))
                }
            })
        let outgoing = scenario == .outgoingFolder || scenario == .lostTrash || scenario == .changedDuringTrash
        let sourceURL = (outgoing ? root : remote.root).appendingPathComponent("selected")
        let destinationURL = (outgoing ? remote.root : root).appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        let isFolder = scenario == .incomingFolder || scenario == .outgoingFolder
        if isFolder {
            try FileManager.default.createDirectory(at: sourceURL.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try remote.bytes.write(to: sourceURL.appendingPathComponent("child"))
            try FileManager.default.createSymbolicLink(atPath: sourceURL.appendingPathComponent("link").path, withDestinationPath: "child")
        } else { try remote.bytes.write(to: sourceURL) }
        let target = destinationURL.appendingPathComponent("selected")
        let queue = FileOperationQueue.shared
        queue.registerLocalTransferService(local)
        let base = try XCTUnwrap(queue.remoteOperationEndpoints[FileOperationQueue.localTransferHostID])
        let localEndpoint = RemoteOperationCoordinator.Endpoint(session: base.session, request: { request in
            if scenario == .lostTrash, case .status = request { throw OperationContractError.invalidReceipt }
            let reply = try await local.reply(request)
            if scenario == .lostTrash, case .execute = request { throw OperationContractError.invalidReceipt }
            return reply
        }, upload: { url, identity in
            let receipt = try await LocalTransferPublication.prepare(url, identity: identity, journal: local.journal)
            if scenario == .competingName { try Data("competing writer".utf8).write(to: target) }
            return receipt
        })
        queue.registerRemoteFileProvider(LocalFileProvider.shared, for: FileOperationQueue.localTransferHostID, operationEndpoint: localEndpoint)
        let service = remote.boundary.service
        let remoteEndpoint = RemoteOperationCoordinator.Endpoint(session: remote.session,
            request: { try await service.reply(to: $0) }, upload: { url, identity in
                try await service.prepareUpload(identity, contents: Data(contentsOf: url))
            })
        let provider = RemoteFileProvider(hostID: remote.hostID, rpcClient: AcceptedProviderRPC(service: service),
                                          transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: remote.hostID, operationEndpoint: remoteEndpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: remote.store) { host in
            if host == remote.hostID { return remoteEndpoint }
            if host == FileOperationQueue.localTransferHostID { return localEndpoint }
            throw OperationContractError.identityMismatch
        }
        let source: Location = outgoing ? .local(sourceURL) : .remote(hostID: remote.hostID, path: sourceURL.path)
        let destination: Location = outgoing ? .remote(hostID: remote.hostID, path: destinationURL.path) : .local(destinationURL)
        do {
            let moved = try await queue.move(items: [source], to: destination)
            XCTAssertEqual(moved, [destination.appendingPathComponent("selected")])
            if scenario == .competingName || scenario == .lostTrash || scenario == .changedDuringTrash { XCTFail("Incomplete move reported complete") }
        } catch {
            if scenario != .competingName && scenario != .lostTrash && scenario != .changedDuringTrash { throw error }
        }
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        if scenario == .competingName {
            XCTAssertEqual(try Data(contentsOf: target), Data("competing writer".utf8))
            XCTAssertEqual(try Data(contentsOf: sourceURL), remote.bytes)
            XCTAssertEqual(result.items.map(\.outcome), [.failedUnchanged, .notStarted])
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destinationURL.path)
                .filter { $0.hasPrefix(".detours-partial-") }.isEmpty)
        } else {
            XCTAssertEqual(try Data(contentsOf: isFolder ? target.appendingPathComponent("child") : target), remote.bytes)
            if isFolder {
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("empty").path))
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path), "child")
            }
            if scenario == .changedDuringTrash {
                XCTAssertEqual(result.items.map(\.outcome), [.committed, .partial])
                XCTAssertEqual(try Data(contentsOf: sourceURL), Data("changed original".utf8))
                XCTAssertEqual(result.items[1].result.receipt?.sourceDisposition, .present)
            } else {
                XCTAssertEqual(result.items.map(\.outcome), [.committed, scenario == .lostTrash ? .unknown : .committed])
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
            }
        }
        if outgoing, scenario != .changedDuringTrash, let item = result.items.last {
            let receipt = try XCTUnwrap(local.journal.read(item.identity.id).receipt)
            let retained = try XCTUnwrap(receipt.recovery.first { $0.purpose == .sourceTrash })
            XCTAssertEqual(retained.original?.path, .unix(Data(sourceURL.path.utf8)))
            guard case .unix(let bytes) = try XCTUnwrap(retained.knownLocation?.path),
                  let path = String(data: bytes, encoding: .utf8) else { return XCTFail("Missing fixture recovery") }
            let trash = URL(fileURLWithPath: path)
            let parent = try OperationDirectory(path: Data(trash.deletingLastPathComponent().path.utf8))
            XCTAssertEqual(try parent.observe(Data(trash.lastPathComponent.utf8)).identity, retained.identity)
            try FileManager.default.removeItem(at: trash)
        }
        await remote.session.disconnect()
        await base.session.disconnect()
    }
}
