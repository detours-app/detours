import AppKit
@testable import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedUndoTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        try await super.tearDown()
    }

    func testUndoManagerRemovesOnlyTheRecordedCopy() async throws { try await run(.copy) }
    func testUndoRefusesChangedCopiedContents() async throws { try await run(.changedCopy) }
    func testUndoRestoresNativeMoveToItsExactOriginalName() async throws { try await run(.move) }
    func testUndoRefusesAnOccupiedOriginalName() async throws { try await run(.occupiedSource) }
    func testEarlierCopyRemainsUndoableAfterLaterFailure() async throws { try await run(.partial) }

    private enum Scenario { case copy, changedCopy, move, occupiedSource, partial }

    private func run(_ scenario: Scenario) async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = configure(fixture)
        let output = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let source = Location.remote(hostID: fixture.hostID, path: fixture.source.path)
        let destination = Location.remote(hostID: fixture.hostID, path: output.path)
        let target = output.appendingPathComponent("source")
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        do {
            if scenario == .move || scenario == .occupiedSource {
                _ = try await queue.move(items: [source], to: destination, undoManager: undo)
            } else {
                let sources = scenario == .partial ? [source, .remote(hostID: fixture.hostID, path: fixture.root.appendingPathComponent("missing").path)] : [source]
                _ = try await queue.copy(items: sources, to: destination, undoManager: undo)
                if scenario == .partial { XCTFail("The missing second item must fail") }
            }
        } catch { if scenario != .partial { throw error } }
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        let original = try XCTUnwrap(queue.remoteOperationResults.values.first)
        if scenario == .changedCopy { try Data("later contents".utf8).write(to: target) }
        if scenario == .occupiedSource { try Data("new occupant".utf8).write(to: fixture.source) }
        if scenario == .copy {
            undo.undo()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while queue.remoteOperationResults.count < 2 || queue.isRunning {
                guard ContinuousClock.now < deadline else { throw OperationContractError.invalidReceipt }
                try await Task.sleep(for: .milliseconds(10))
            }
        } else {
            do {
                _ = try await queue.undoAcceptedOperation(original)
                if scenario == .changedCopy || scenario == .occupiedSource { XCTFail("Unsafe undo succeeded") }
            } catch { if scenario != .changedCopy && scenario != .occupiedSource { throw error } }
        }
        let reverse = try XCTUnwrap(queue.remoteOperationResults.values.first(where: { $0.record.operation != original.record.operation }))
        XCTAssertTrue(reverse.items.allSatisfy { $0.result.intent.reverses != nil })
        if scenario == .changedCopy {
            XCTAssertEqual(try Data(contentsOf: target), Data("later contents".utf8))
            XCTAssertEqual(reverse.items.map(\.preflightFailure), [.recoveryChanged])
        } else if scenario == .occupiedSource {
            XCTAssertEqual(try Data(contentsOf: target), fixture.bytes)
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("new occupant".utf8))
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            XCTAssertTrue(reverse.items.allSatisfy { $0.outcome == .committed })
        }
    }

    func testReplacementUndoRetainsNewContentsAndRestoresRecordedOriginal() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = configure(fixture)
        let previous = Data("original destination".utf8)
        let output = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let destinationFile = output.appendingPathComponent("source")
        try previous.write(to: destinationFile)
        queue.conflictChoiceOverrideForTesting = .replace
        defer { queue.conflictChoiceOverrideForTesting = nil }
        _ = try await queue.copy(items: [.remote(hostID: fixture.hostID, path: fixture.source.path)],
            to: .remote(hostID: fixture.hostID, path: output.path))
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        guard let conflict = result.items.first?.result.intent.conflict, case .replace(let approved) = conflict else {
            return XCTFail("Missing replacement intent")
        }
        XCTAssertNotNil(approved.sha256)
        let reversed = try await queue.undoAcceptedOperation(result)
        XCTAssertEqual(reversed.items.map { $0.result.intent.action }, [.trash, .restore])
        XCTAssertEqual(try Data(contentsOf: destinationFile), previous)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        let retained = try XCTUnwrap(reversed.items.first?.result.receipt?.recovery.first(where: { $0.purpose == .sourceTrash })?.knownLocation)
        guard case .unix(let bytes) = retained.path else { return XCTFail("Expected Unix recovery path") }
        let path = try XCTUnwrap(String(bytes: bytes, encoding: .utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), fixture.bytes)
        let refreshed = try XCTUnwrap(queue.remoteOperationResults[result.record.operation]?.items.first)
        XCTAssertFalse(RemoteOperationCoordinator.canRestoreOriginal(refreshed))
    }

    func testRestoredTrashNoLongerOffersConsumedRecovery() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = configure(fixture)
        let output = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let copied = try await queue.copy(items: [.remote(hostID: fixture.hostID, path: fixture.source.path)],
            to: .remote(hostID: fixture.hostID, path: output.path))
        XCTAssertEqual(copied.count, 1)
        let original = try XCTUnwrap(queue.remoteOperationResults.values.first)
        let trashed = try await queue.undoAcceptedOperation(original)
        _ = try await queue.undoAcceptedOperation(trashed)
        let refreshed = try XCTUnwrap(queue.remoteOperationResults[trashed.record.operation])
        XCTAssertTrue(refreshed.items.allSatisfy { !RemoteOperationCoordinator.canUndo($0, in: refreshed) })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied[0].path)), fixture.bytes)
    }

    func testCreationRenameAndArchiveCallersRegisterReceiptBoundUndo() async throws {
        for kind in ["file", "folder", "renamedFolder", "rename", "archive", "extract"] {
            FileOperationQueue.shared.resetRemoteQueueStateForTesting()
            let fixture = try await CoordinatorFixture()
            defer { fixture.cleanup() }
            let queue = configure(fixture)
            let directory = Location.remote(hostID: fixture.hostID, path: fixture.root.path)
            let source = Location.remote(hostID: fixture.hostID, path: fixture.source.path)
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            let created: Location
            switch kind {
            case "file": created = try await queue.createFile(in: directory, name: "new.txt", content: fixture.bytes, undoManager: undo)
            case "folder": created = try await queue.createFolder(in: directory, name: "new folder", undoManager: undo)
            case "renamedFolder":
                let folder = try await queue.createFolder(in: directory, name: "Folder")
                created = try await queue.rename(item: folder, to: "named folder")
                try await queue.registerCreatedRemoteUndo(created, with: undo)
            case "rename": created = try await queue.rename(item: source, to: "renamed", undoManager: undo)
            case "archive": created = try await queue.archive(items: [source], format: .zip, archiveName: "archive", password: nil, undoManager: undo)
            default:
                let archive = try await queue.archive(items: [source], format: .zip, archiveName: "archive", password: nil)
                created = try await queue.extract(archive: archive, undoManager: undo)
            }
            undo.endUndoGrouping()
            XCTAssertTrue(undo.canUndo, kind)
            let count = queue.remoteOperationResults.count
            undo.undo()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while queue.remoteOperationResults.count == count || queue.isRunning {
                guard ContinuousClock.now < deadline else { throw OperationContractError.invalidReceipt }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: created.path), kind)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes, kind)
            XCTAssertTrue(queue.remoteOperationResults.values.contains { snapshot in
                snapshot.items.contains { $0.result.intent.reverses != nil && $0.outcome == .committed }
            }, kind)
        }
    }

    func testNewFolderCancellationRefusesLaterContents() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = configure(fixture)
        let created = try await queue.createFolder(in: .remote(hostID: fixture.hostID, path: fixture.root.path), name: "Folder")
        let child = URL(fileURLWithPath: created.path).appendingPathComponent("later file")
        try fixture.bytes.write(to: child)
        do {
            try await queue.cancelCreatedRemoteItem(created)
            XCTFail("Cancelled creation removed later contents")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: child), fixture.bytes)
    }

    func testCreationCancellationCannotRemoveAnOrdinaryRenamedFile() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = configure(fixture)
        let renamed = try await queue.rename(item: .remote(hostID: fixture.hostID, path: fixture.source.path), to: "Folder")
        do {
            try await queue.cancelCreatedRemoteItem(renamed)
            XCTFail("An ordinary rename is not evidence of creation")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: renamed.path)), fixture.bytes)
    }

    func testRestoreOriginalAfterPartialReplacementNeverOverwritesOccupant() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = configure(fixture, blockReplacement: true)
        let output = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let destination = output.appendingPathComponent("source")
        let originalBytes = Data("retained original".utf8)
        try originalBytes.write(to: destination)
        queue.conflictChoiceOverrideForTesting = .replace
        defer { queue.conflictChoiceOverrideForTesting = nil }
        do {
            _ = try await queue.copy(items: [.remote(hostID: fixture.hostID, path: fixture.source.path)],
                to: .remote(hostID: fixture.hostID, path: output.path))
            XCTFail("Competing writer must leave a partial replacement")
        } catch {}
        let failed = try XCTUnwrap(queue.remoteOperationResults.values.first?.items.first)
        XCTAssertEqual(failed.outcome, .partial)
        XCTAssertTrue(RemoteOperationCoordinator.canRestoreOriginal(failed))
        do {
            _ = try await queue.restoreAcceptedOriginal(failed)
            XCTFail("Restore Original overwrote a later occupant")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("competing writer".utf8))
        let preserved = output.appendingPathComponent("preserved occupant")
        try FileManager.default.moveItem(at: destination, to: preserved)
        let restored = try await queue.restoreAcceptedOriginal(failed)
        XCTAssertEqual(restored.items.map(\.outcome), [.committed])
        XCTAssertNil(restored.items.first?.result.receipt?.failure)
        XCTAssertEqual(restored.items.first?.result.intent.reverses, failed.identity.id)
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        XCTAssertEqual(try Data(contentsOf: preserved), Data("competing writer".utf8))
        let refreshed = try XCTUnwrap(queue.remoteOperationResults[failed.identity.id.operation]?.items.first)
        XCTAssertFalse(RemoteOperationCoordinator.canRestoreOriginal(refreshed))
    }

    private func configure(_ fixture: CoordinatorFixture, blockReplacement: Bool = false) -> FileOperationQueue {
        let service = fixture.boundary.service
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { request in
                if blockReplacement, case .commit(let identity) = request {
                    let ownership = try await service.journal.acquireItem(identity.id)
                    defer { withExtendedLifetime(ownership) {} }
                    let commit = try await service.journal.acquireCommit()
                    defer { withExtendedLifetime(commit) {} }
                    let snapshot = try service.journal.read(identity.id)
                    _ = try OperationReplacement.displace(journal: service.journal, snapshot: snapshot, ownership: ownership)
                    let destination = try XCTUnwrap(snapshot.intent?.destination)
                    guard case .unix(let bytes) = destination.path, let path = String(data: bytes, encoding: .utf8) else {
                        throw OperationContractError.invalidReceipt
                    }
                    try Data("competing writer".utf8).write(to: URL(fileURLWithPath: path))
                    try OperationReplacement.restore(journal: service.journal, id: identity.id, ownership: ownership, failure: "Publication interrupted")
                    return .receipt(try XCTUnwrap(service.journal.read(identity.id).receipt))
                }
                return try await service.reply(to: request)
            }, upload: { url, identity in
                try await service.prepareUpload(identity, contents: Data(contentsOf: url))
            })
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { _ in endpoint }
        return queue
    }
}
