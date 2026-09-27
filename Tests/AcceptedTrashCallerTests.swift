import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedTrashCallerTests: XCTestCase {
    private var explainerPreference: Any?

    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        explainerPreference = UserDefaults.standard.object(forKey: RemoteTrashExplainer.dismissedDefaultsKey)
        UserDefaults.standard.set(true, forKey: RemoteTrashExplainer.dismissedDefaultsKey)
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        if let explainerPreference {
            UserDefaults.standard.set(explainerPreference, forKey: RemoteTrashExplainer.dismissedDefaultsKey)
        } else { UserDefaults.standard.removeObject(forKey: RemoteTrashExplainer.dismissedDefaultsKey) }
        try await super.tearDown()
    }

    func testPublicTrashRestoresTheRecordedFile() async throws { try await run(.file) }
    func testPublicTrashRestoresTheCompleteFolder() async throws { try await run(.folder) }
    func testOccupiedOriginalPreventsRestore() async throws { try await run(.occupied) }
    func testChangedHeldFilePreventsRestore() async throws { try await run(.changed) }
    func testLostTrashReplyIsReconciledBeforeRestore() async throws { try await run(.lostReply) }
    func testLaterTrashFailureKeepsEarlierItemRestorable() async throws { try await run(.partial) }
    func testConfirmedPermanentDeleteUsesAcceptedContext() async throws { try await run(.permanent) }

    private enum Scenario: Sendable { case file, folder, occupied, changed, lostReply, partial, permanent }

    private func run(_ scenario: Scenario) async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let service = fixture.boundary.service
        let later = fixture.root.appendingPathComponent("later")
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            if scenario == .partial, case .execute(let identity) = request,
               try service.status(identity).intent?.sources.first?.path == .unix(Data(later.path.utf8)) {
                try Data("later changed".utf8).write(to: later)
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
        var source = fixture.source
        if scenario == .folder {
            source = fixture.root.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try fixture.bytes.write(to: source.appendingPathComponent("child"))
        }
        let original = try OperationDirectory(path: Data(fixture.root.path.utf8)).observe(Data(source.lastPathComponent.utf8))
        let location = Location.remote(hostID: fixture.hostID, path: source.path)
        var items = [location]
        if scenario == .partial {
            try fixture.bytes.write(to: later)
            items.append(.remote(hostID: fixture.hostID, path: later.path))
        }
        do {
            if scenario == .permanent { try await queue.deleteImmediately(items: items) } else { try await queue.delete(items: items) }
            if scenario == .partial { XCTFail("Partial Trash reported complete") }
        } catch { if scenario != .partial { throw error } }
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        XCTAssertEqual(result.items.map(\.outcome), scenario == .partial ? [.committed, .failedUnchanged] : [.committed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        if scenario == .permanent {
            XCTAssertEqual(result.items.first?.result.intent.action, .permanentDelete)
            XCTAssertFalse(result.items.first?.result.receipt?.recovery.contains { $0.purpose == .sourceTrash } == true)
            return
        }
        let retained = try XCTUnwrap(result.items.first?.result.receipt?.recovery.first { $0.purpose == .sourceTrash })
        XCTAssertEqual(retained.identity, original.identity)
        guard case .unix(let bytes) = retained.knownLocation?.path, let path = String(data: bytes, encoding: .utf8) else {
            return XCTFail("Missing confirmed Trash location")
        }
        let held = URL(fileURLWithPath: path)
        if scenario == .occupied { try Data("competing writer".utf8).write(to: source) }
        if scenario == .changed { try Data("changed held".utf8).write(to: held) }
        do {
            let restored = try await queue.restoreAcceptedTrash(result)
            XCTAssertEqual(restored, [location])
            if scenario == .occupied || scenario == .changed { XCTFail("Unsafe restore succeeded") }
        } catch { if scenario != .occupied && scenario != .changed { throw error } }
        if scenario == .occupied {
            XCTAssertEqual(try Data(contentsOf: source), Data("competing writer".utf8))
            XCTAssertEqual(try Data(contentsOf: held), fixture.bytes)
        } else if scenario == .changed {
            XCTAssertEqual(try Data(contentsOf: held), Data("changed held".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        } else {
            XCTAssertEqual(try Data(contentsOf: scenario == .folder ? source.appendingPathComponent("child") : source), fixture.bytes)
            XCTAssertEqual(try OperationDirectory(path: Data(fixture.root.path.utf8)).observe(Data(source.lastPathComponent.utf8)).identity,
                           original.identity)
            if scenario == .folder { XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("empty").path)) }
            if scenario == .partial { XCTAssertEqual(try Data(contentsOf: later), Data("later changed".utf8)) }
        }
    }
}
