import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerOperationServiceTests: XCTestCase {
    func testAcceptedUploadsRequireSeparateCommitAndRetainOneResult() async throws {
        for size in [0, 1_048_575, 1_048_576] {
            let fixture = try await Fixture(size: size)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let prepared = try await fixture.service.prepareUpload(fixture.identity, contents: fixture.bytes)
            XCTAssertEqual(prepared.phase, .readyToCommit)
            XCTAssertEqual(prepared.preparedPayload?.observation.sha256, fixture.intent.payloadProof?.sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertNotNil(try fixture.service.status(fixture.identity).workspace)
            let committed = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(committed.outcome, .committed)
            XCTAssertEqual(committed.phase, .terminal)
            XCTAssertTrue(committed.recovery.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
            let duplicate = try await fixture.service.commit(fixture.identity)
            XCTAssertEqual(duplicate, committed)
            try await fixture.service.acknowledge(fixture.identity, retainingUndo: false)
            XCTAssertTrue(try fixture.service.status(fixture.identity).acknowledged)
        }
    }

    func testRPCDispatchAcceptsPreparesCommitsAndReturnsTheSameResult() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        let handler = RPCHandler(operationService: fixture.service)
        func send(_ request: OperationRequest) throws -> OperationReply {
            let decoded = try OperationRequest.decode(request.encoded())
            return try OperationReply.decode(handler.handle(message: .operation(decoded)))
        }
        guard case .accepted = try send(.accept(identity: fixture.identity, intent: fixture.intent)) else {
            return XCTFail("RPC did not durably accept upload")
        }
        guard case .receipt(let ready) = try send(.prepareUpload(identity: fixture.identity, contents: fixture.bytes)) else {
            return XCTFail("RPC did not prepare upload")
        }
        XCTAssertEqual(ready.phase, .readyToCommit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let committed = try send(.commit(fixture.identity))
        guard case .receipt(let receipt) = committed else { return XCTFail("RPC did not return a receipt") }
        XCTAssertEqual(receipt.outcome, .committed)
        XCTAssertEqual(try send(.commit(fixture.identity)), committed)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
    }

    func testNativeRenameMoveAndFolderCreationKeepOneRecordedResult() async throws {
        for action in [OperationIntent.Action.rename, .move, .createFolder] {
            let fixture = try await Fixture(size: 32, action: action)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let result = try await fixture.service.execute(fixture.identity)
            XCTAssertEqual(result.outcome, .committed)
            XCTAssertEqual(result.effects.first?.observation.kind, action == .createFolder ? .directory : .file)
            let duplicate = try await fixture.service.execute(fixture.identity)
            XCTAssertEqual(duplicate, result)
            if action != .createFolder {
                XCTAssertEqual(result.sourceDisposition, .confirmed)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("source").path))
                XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
            }
        }
    }

    func testNativeConflictAndChangedSourceLeaveUserFilesUntouched() async throws {
        for changedSource in [false, true] {
            let fixture = try await Fixture(size: 32, action: .move)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let source = fixture.root.appendingPathComponent("source")
            let competitor = Data("other writer".utf8)
            try competitor.write(to: changedSource ? source : fixture.destination)
            let result = try await fixture.service.execute(fixture.identity)
            XCTAssertEqual(result.outcome, .failedUnchanged)
            XCTAssertTrue(result.effects.isEmpty)
            XCTAssertEqual(try Data(contentsOf: changedSource ? source : fixture.destination), competitor)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.destination.path), !changedSource)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testNativeCancellationBeforeMutationIsConfirmedUnchanged() async throws {
        let fixture = try await Fixture(size: 32, action: .rename)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        try fixture.service.cancel(fixture.identity)
        let result = try await fixture.service.execute(fixture.identity)
        XCTAssertEqual(result.outcome, .failedUnchanged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("source").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testNativeMoveChecksDeclaredSourceContentBeforeMutation() async throws {
        for valid in [false, true] {
            let hash = try OperationContentProof.data(Data(repeating: valid ? 42 : 7, count: 32)).sha256
            let fixture = try await Fixture(size: 32, action: .move, sourceHash: hash)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            let result = try await fixture.service.execute(fixture.identity)
            XCTAssertEqual(result.outcome, valid ? .committed : .failedUnchanged)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.destination.path), valid)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("source").path), !valid)
            if valid { XCTAssertEqual(result.effects.first?.observation.sha256, hash) }
        }
    }

    func testStoppedFolderCreationCannotClaimAnUnrecordedDirectory() async throws {
        let fixture = try await Fixture(size: 0, action: .createFolder)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        do {
            let ownership = try await fixture.service.journal.acquireItem(fixture.identity.id)
            try fixture.service.journal.record(OperationReceipt(
                id: fixture.identity.id, account: fixture.identity.account, epoch: fixture.identity.epoch,
                intentDigest: fixture.identity.intentDigest, revision: 1, phase: .committing, outcome: .running,
                plannedPaths: [try XCTUnwrap(fixture.intent.destination)]
            ), ownership: ownership)
        }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertTrue(result.effects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(result.plannedPaths, [try XCTUnwrap(fixture.intent.destination)])
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt, result)
    }

    func testLostNativeMoveConclusionIsReconciledWithoutAnotherMove() async throws {
        let fixture = try await Fixture(size: 32, action: .move)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let source = try XCTUnwrap(fixture.intent.sources.first)
        let expected = try XCTUnwrap(fixture.intent.sourceObservations.first)
        let destination = try XCTUnwrap(fixture.intent.destination)
        do {
            let ownership = try await fixture.service.journal.acquireItem(fixture.identity.id)
            try fixture.service.journal.record(OperationReceipt(
                id: fixture.identity.id, account: fixture.identity.account, epoch: fixture.identity.epoch,
                intentDigest: fixture.identity.intentDigest, revision: 1, phase: .committing, outcome: .running,
                sourceDisposition: .unknown, preparedPayload: OperationEffect(location: source, observation: expected),
                recovery: [OperationRecoveryReference(identity: expected.identity, purpose: .source, original: source,
                                                        knownLocation: nil, possibleLocations: [source, destination])]
            ), ownership: ownership)
            let directory = try OperationDirectory(path: Data(fixture.root.path.utf8))
            _ = try directory.moveExclusive(Data("source".utf8), to: directory, named: Data("destination".utf8), expected: expected)
            XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.phase, .committing)
            withExtendedLifetime(ownership) {}
        }
        let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.sourceDisposition, .confirmed)
        XCTAssertTrue(result.recovery.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt, result)
    }

    func testWrongByteCountOrHashLeavesDestinationUntouched() async throws {
        for bad in [Data([1]), Data(repeating: 7, count: 32)] {
            let fixture = try await Fixture(size: 32)
            defer { fixture.cleanup() }
            _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
            do {
                _ = try await fixture.service.prepareUpload(fixture.identity, contents: bad)
                XCTFail("Mismatching bytes were accepted")
            } catch { XCTAssertEqual(error as? OperationContractError, .invalidReceipt) }
            XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["journal"])
        }
    }

    func testLargeStreamUsesVerifiedPreparationBeforeSeparateCommit() async throws {
        let fixture = try await Fixture(size: 1_048_577)
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        try fixture.bytes.write(to: source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let ready = try await fixture.service.prepareStream(fixture.identity, input: input)
        XCTAssertEqual(ready.phase, .readyToCommit)
        XCTAssertEqual(ready.preparedPayload?.observation.sha256, fixture.intent.payloadProof?.sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let committed = try await fixture.service.commit(fixture.identity)
        XCTAssertEqual(committed.outcome, .committed)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
    }

    func testTransferModeReturnsPreparedReceiptWithoutPublishing() async throws {
        let fixture = try await Fixture(size: 1_048_577)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let handshake = try OperationStreamHandshake(identity: fixture.identity).encoded()
        let header = Data([3]) + handshake
        var length = UInt32(header.count).bigEndian
        let inputURL = fixture.root.appendingPathComponent("input")
        let outputURL = fixture.root.appendingPathComponent("output")
        try (Data(bytes: &length, count: 4) + header + fixture.bytes).write(to: inputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try SafeFileWriter.createHandle(at: outputURL)
        defer {
            try? input.close()
            try? output.close()
        }
        try TransferMode(input: input, output: output, operationService: fixture.service).run()
        let response = try Data(contentsOf: outputURL)
        let responseLength = response.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(response.count, Int(responseLength) + 4)
        guard case .receipt(let ready) = try OperationReply.decode(Data(response.dropFirst(4))) else {
            return XCTFail("Stream did not return preparation receipt")
        }
        XCTAssertEqual(ready.phase, .readyToCommit)
        XCTAssertTrue(ready.contentVerified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let committed = try await fixture.service.commit(fixture.identity)
        XCTAssertEqual(committed.outcome, .committed)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
    }

    func testStalledStreamReleasesAccountLockAndHonoursIndependentCancellation() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        let pipe = Pipe()
        defer {
            try? fixture.service.cancel(fixture.identity)
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let worker = Task { try await fixture.service.prepareStream(fixture.identity, input: pipe.fileHandleForReading) }
        let clock = ContinuousClock()
        let started = clock.now
        while try fixture.service.status(fixture.identity).workspace == nil {
            guard clock.now - started < .seconds(5) else {
                try fixture.service.cancel(fixture.identity)
                _ = try? await worker.value
                return XCTFail("Stream did not reach private preparation")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            let otherCommit = try await fixture.service.journal.acquireCommit()
            XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.phase, .preparing)
            withExtendedLifetime(otherCommit) {}
        }
        let cancelling = clock.now
        try fixture.service.cancel(fixture.identity)
        do {
            _ = try await worker.value
            XCTFail("Stalled stream ignored cancellation")
        } catch { XCTAssertEqual(error as? OperationContractError, .cancelled) }
        XCTAssertLessThan(clock.now - cancelling, .seconds(3))
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["journal"])
    }

    func testShortStreamLeavesDestinationUntouched() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data([42]))
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        do {
            _ = try await fixture.service.prepareStream(fixture.identity, input: pipe.fileHandleForReading)
            XCTFail("Short stream was accepted")
        } catch { XCTAssertEqual(error as? OperationContractError, .invalidReceipt) }
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt?.outcome, .failedUnchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testStatusAndCancellationDoNotNeedWorkerOwnership() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let ownership = try await fixture.service.journal.acquireItem(fixture.identity.id)
        XCTAssertNil(try fixture.service.status(fixture.identity).receipt)
        try fixture.service.cancel(fixture.identity)
        XCTAssertTrue(try fixture.service.journal.cancellationRequested(fixture.identity.id))
        withExtendedLifetime(ownership) {}
    }

    func testOpenWorkerRejectsResetJournalEpoch() async throws {
        let fixture = try await Fixture(size: 1)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let journalRoot = fixture.root.appendingPathComponent("journal")
        try FileManager.default.removeItem(at: journalRoot.appendingPathComponent("epoch.json"))
        _ = try await OperationJournal(root: journalRoot, account: fixture.identity.account)
        XCTAssertThrowsError(try fixture.service.status(fixture.identity)) {
            XCTAssertEqual($0 as? OperationContractError, .epochMismatch)
        }
        XCTAssertThrowsError(try fixture.service.cancel(fixture.identity))
    }

    func testOpenWorkerRejectsReplacedJournalDirectory() async throws {
        let fixture = try await Fixture(size: 1)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let journalRoot = fixture.root.appendingPathComponent("journal")
        try FileManager.default.moveItem(at: journalRoot, to: fixture.root.appendingPathComponent("old-journal"))
        let replacement = try await OperationJournal(root: journalRoot, account: fixture.identity.account)
        XCTAssertNotEqual(replacement.epoch, fixture.identity.epoch)
        XCTAssertThrowsError(try fixture.service.status(fixture.identity)) {
            XCTAssertEqual($0 as? OperationContractError, .epochMismatch)
        }
        XCTAssertThrowsError(try fixture.service.cancel(fixture.identity))
        do {
            _ = try await fixture.service.journal.acquireCommit()
            XCTFail("Replaced journal admitted an old worker")
        } catch { XCTAssertEqual(error as? OperationContractError, .epochMismatch) }
    }

    func testStatusProvesLostPublicationWithoutRepeatingOrCleaningIt() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let ready = try await fixture.service.prepareUpload(fixture.identity, contents: fixture.bytes)
        let payload = try XCTUnwrap(ready.preparedPayload)
        let uncertain = try await fixture.stageInterruptedPublication(ready)
        XCTAssertEqual(uncertain.phase, .committing)
        guard case .unix(let bytes) = payload.location.path else { return XCTFail("Expected Unix payload") }
        let payloadURL = URL(fileURLWithPath: try XCTUnwrap(String(data: bytes, encoding: .utf8)))
        let source = try OperationDirectory(path: Data(payloadURL.deletingLastPathComponent().path.utf8))
        let destination = try OperationDirectory(path: Data(fixture.root.path.utf8))
        _ = try source.moveExclusive(Data(payloadURL.lastPathComponent.utf8), to: destination,
                                     named: Data("destination".utf8), expected: payload.observation)
        let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.effects.first?.observation.identity, payload.observation.identity)
        XCTAssertEqual(result.recovery.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.deletingLastPathComponent().path))
        XCTAssertEqual(try fixture.service.status(fixture.identity).receipt, result)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
    }

    func testStatusKeepsIdenticalCompetingContentUnknownAndDoesNotResumeUpload() async throws {
        let fixture = try await Fixture(size: 32)
        defer { fixture.cleanup() }
        _ = try await fixture.service.accept(fixture.identity, intent: fixture.intent)
        let ready = try await fixture.service.prepareUpload(fixture.identity, contents: fixture.bytes)
        _ = try await fixture.stageInterruptedPublication(ready)
        try fixture.bytes.write(to: fixture.destination)
        let result = try XCTUnwrap(fixture.service.status(fixture.identity).receipt)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertTrue(result.effects.isEmpty)
        XCTAssertEqual(result.recovery.count, ready.recovery.count)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertNotNil(try fixture.service.status(fixture.identity).workspace)
    }

    private struct Fixture {
        let root: URL
        let destination: URL
        let bytes: Data
        let service: ServerOperationService
        let identity: OperationRequestIdentity
        let intent: OperationIntent

        init(size: Int, action: OperationIntent.Action = .copy, sourceHash: String? = nil) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.root = root
            self.destination = root.appendingPathComponent("destination")
            self.bytes = Data(repeating: 42, count: size)
            let account = OperationAccount(hostIdentity: "fixture", accountIdentity: "fixture-user")
            let service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account)
            self.service = service
            var sources: [OperationLocation] = []
            var observations: [OperationObservation] = []
            if [.rename, .move].contains(action) {
                let source = root.appendingPathComponent("source")
                try bytes.write(to: source)
                sources = [OperationLocation(account: account, path: .unix(Data(source.path.utf8)))]
                let observed = try OperationDirectory(path: Data(root.path.utf8)).observe(Data("source".utf8))
                observations = [OperationObservation(identity: observed.identity, kind: observed.kind, version: observed.version,
                                                     byteCount: observed.byteCount, sha256: sourceHash, linkTarget: observed.linkTarget,
                                                     contentVersion: observed.contentVersion)]
            }
            let intent = OperationIntent(
                id: .init(operation: UUID(), item: UUID()), action: action, sources: sources,
                destination: OperationLocation(account: account, path: .unix(Data(destination.path.utf8))),
                sourceObservations: observations, conflict: .createNew,
                payloadProof: action == .copy ? try OperationContentProof.data(bytes) : nil
            )
            self.intent = intent
            self.identity = OperationRequestIdentity(id: intent.id, account: account, epoch: service.journal.epoch,
                                                      intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func stageInterruptedPublication(_ ready: OperationReceipt) async throws -> OperationReceipt {
            let ownership = try await service.journal.acquireItem(identity.id)
            let payload = try XCTUnwrap(ready.preparedPayload)
            let uncertain = OperationRecoveryReference(
                identity: payload.observation.identity, purpose: .scratch, original: nil, knownLocation: nil,
                possibleLocations: [payload.location, try XCTUnwrap(intent.destination)]
            )
            let receipt = OperationReceipt(
                id: identity.id, account: identity.account, epoch: identity.epoch, intentDigest: identity.intentDigest,
                revision: ready.revision + 1, phase: .committing, outcome: .running,
                contentVerified: true, preparedPayload: payload,
                recovery: ready.recovery.filter { $0.identity != payload.observation.identity } + [uncertain]
            )
            try service.journal.record(receipt, ownership: ownership)
            XCTAssertEqual(try service.status(identity).receipt, receipt)
            withExtendedLifetime(ownership) {}
            return receipt
        }
    }
}
