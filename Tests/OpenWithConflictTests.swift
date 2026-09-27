import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server
@testable import Detours

@MainActor
final class OpenWithConflictTests: XCTestCase {
    func testHashMismatchSurfacesConflict() {
        let original = RemoteFileVersion(sha256: "old", modificationDate: Date(timeIntervalSince1970: 100))
        let current = RemoteFileVersion(sha256: "new", modificationDate: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(FileOpenHelper.conflictKind(original: original, current: current), .content)
    }

    func testMtimeMismatchSurfacesConflict() {
        let original = RemoteFileVersion(sha256: "same", modificationDate: Date(timeIntervalSince1970: 100))
        let current = RemoteFileVersion(sha256: "same", modificationDate: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(FileOpenHelper.conflictKind(original: original, current: current), .timestamp)
    }

    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testCleanRoundtripUploads() async throws { try await save(.clean) }
    func testKeepMineRetainsTheApprovedRemoteOriginal() async throws { try await save(.keepMine) }
    func testKeepRemotePublishesNothing() async throws { try await save(.keepRemote) }
    func testCancelledConflictPublishesNothing() async throws { try await save(.cancel) }
    func testRemoteChangeAfterApprovalRefusesReplacement() async throws { try await save(.changedAfterApproval) }
    func testUploadFailurePreservesTheRemoteAndEditedFiles() async throws { try await save(.uploadFailure) }

    private enum Scenario { case clean, keepMine, keepRemote, cancel, changedAfterApproval, uploadFailure }

    private func save(_ scenario: Scenario) async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let boundary = EditorUploadBoundary(service: fixture.boundary.service, failUpload: scenario == .uploadFailure)
        let provider = configure(fixture, boundary: boundary)
        let location = Location.remote(hostID: fixture.hostID, path: fixture.source.path)
        let version = try await provider.version(of: location)
        let local = fixture.root.appendingPathComponent("edited")
        try Data("mine".utf8).write(to: local)
        let session = RemoteOpenWithSession(remoteLocation: location, localURL: local, originalVersion: version)
        let conflictExpected = [.keepMine, .keepRemote, .cancel, .changedAfterApproval].contains(scenario)
        if conflictExpected { try Data("remote edit".utf8).write(to: fixture.source) }
        do {
            let choice = try await FileOpenHelper.finishRemoteOpenWith(session, provider: provider) { _ in
                XCTAssertTrue(conflictExpected)
                if scenario == .changedAfterApproval {
                    do { try Data("later remote edit".utf8).write(to: fixture.source) } catch { XCTFail("\(error)") }
                }
                if scenario == .keepRemote { return .keepRemote }
                if scenario == .cancel { return .cancel }
                return .keepMine
            }
            if scenario == .uploadFailure || scenario == .changedAfterApproval { XCTFail("Unsafe editor save succeeded") }
            if scenario == .clean { XCTAssertNil(choice) }
        } catch {
            if scenario != .uploadFailure && scenario != .changedAfterApproval { throw error }
        }
        XCTAssertEqual(try Data(contentsOf: local), Data("mine".utf8))
        let results = FileOperationQueue.shared.remoteOperationResults
        switch scenario {
        case .keepRemote, .cancel:
            XCTAssertTrue(results.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("remote edit".utf8))
        case .changedAfterApproval:
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("later remote edit".utf8))
            XCTAssertEqual(try XCTUnwrap(results.values.first).items.map(\.outcome), [.failedUnchanged])
        case .uploadFailure:
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            XCTAssertFalse(try XCTUnwrap(results.values.first).items.contains { $0.outcome == .committed })
        case .clean, .keepMine:
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("mine".utf8))
            let result = try XCTUnwrap(results.values.first)
            XCTAssertEqual(result.items.map(\.outcome), [.committed])
            XCTAssertEqual(result.items.first?.result.intent.action, .editorUpload)
            let receipt = try XCTUnwrap(result.items.first?.result.receipt)
            let backup = try XCTUnwrap(receipt.recovery.first { $0.purpose == .displacedOriginal }?.knownLocation)
            guard case .unix(let bytes) = backup.path, let path = String(data: bytes, encoding: .utf8) else {
                return XCTFail("Missing retained original")
            }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)),
                           scenario == .clean ? fixture.bytes : Data("remote edit".utf8))
        }
    }

    func testSaveDuringActiveUploadQueuesNewestUpload() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let boundary = EditorUploadBoundary(service: fixture.boundary.service, pauseFirst: true)
        let provider = configure(fixture, boundary: boundary)
        let location = Location.remote(hostID: fixture.hostID, path: fixture.source.path)
        let version = try await provider.version(of: location)
        let local = fixture.root.appendingPathComponent("edited")
        try Data("mine".utf8).write(to: local)
        let session = RemoteOpenWithSession(remoteLocation: location, localURL: local, originalVersion: version)
        let coordinator = RemoteOpenWithCoordinator.shared
        coordinator.beginSessionForTesting(session, provider: provider)
        defer { coordinator.endSessionForTesting(localURL: local) }
        let first = Task { await coordinator.uploadIfNeededForTesting(localURL: local) }
        do {
            try await waitFor { await boundary.uploadCount == 1 }
            try Data("newest".utf8).write(to: local)
            await coordinator.uploadIfNeededForTesting(localURL: local)
            await boundary.releaseFirstUpload()
            await first.value
        } catch {
            await boundary.releaseFirstUpload()
            first.cancel()
            await first.value
            throw error
        }
        let count = await boundary.uploadCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("newest".utf8))
        XCTAssertEqual(FileOperationQueue.shared.remoteOperationResults.count, 2)
        XCTAssertTrue(FileOperationQueue.shared.remoteOperationResults.values.allSatisfy { $0.items.allSatisfy { $0.outcome == .committed } })
    }

    private func configure(_ fixture: CoordinatorFixture, boundary: EditorUploadBoundary) -> RemoteFileProvider {
        let service = fixture.boundary.service
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { try await service.reply(to: $0) }, upload: { try await boundary.upload($0, identity: $1) })
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { host in
            guard host == fixture.hostID else { throw OperationContractError.identityMismatch }
            return endpoint
        }
        return provider
    }

    private func waitFor(condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw OperationContractError.invalidReceipt }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor EditorUploadBoundary {
    let service: ServerOperationService
    let pauseFirst: Bool
    let failUpload: Bool
    private(set) var uploadCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(service: ServerOperationService, pauseFirst: Bool = false, failUpload: Bool = false) {
        self.service = service
        self.pauseFirst = pauseFirst
        self.failUpload = failUpload
    }

    func releaseFirstUpload() {
        continuation?.resume()
        continuation = nil
    }

    func upload(_ url: URL, identity: OperationRequestIdentity) async throws -> OperationReceipt {
        if failUpload { throw OperationContractError.invalidReceipt }
        let result = try await service.prepareUpload(identity, contents: Data(contentsOf: url))
        uploadCount += 1
        if pauseFirst && uploadCount == 1 { await withCheckedContinuation { continuation = $0 } }
        return result
    }
}
