import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

final class AcceptedProviderTests: XCTestCase {
    func testUnixAcceptedSmallUploadRequiresAcceptanceAndSeparateCommit() async throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let account = OperationAccount(hostIdentity: "provider-host", accountIdentity: "provider-account")
        let service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account)
        let rpc = AcceptedProviderRPC(service: service)
        let provider: any FileProvider = RemoteFileProvider(hostID: UUID(), rpcClient: rpc,
                                                          transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        for size in [0, 1_048_575, 1_048_576] {
            let bytes = Data(repeating: 71, count: size)
            let source = root.appendingPathComponent("source-\(size)")
            let destination = root.appendingPathComponent("destination-\(size)")
            try bytes.write(to: source)
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy,
                                         sources: [], destination: .init(account: account, path: .unix(Data(destination.path.utf8))),
                                         sourceObservations: [], conflict: .createNew, payloadProof: try .data(bytes))
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: service.journal.epoch,
                                                     intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            do {
                _ = try await provider.prepareAcceptedUpload(source, identity: identity)
                XCTFail("Upload without accepted intent reached preparation")
            } catch OperationJournalError.missingRecord {}
            _ = try await provider.operationRequest(.accept(identity: identity, intent: intent))
            let ready = try await provider.prepareAcceptedUpload(source, identity: identity)
            XCTAssertEqual(ready.phase, .readyToCommit)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            guard case .receipt(let receipt) = try await provider.operationRequest(.commit(identity)) else {
                return XCTFail("Provider did not return the host receipt")
            }
            XCTAssertEqual(receipt.outcome, .committed)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }
    }

    func testOperationPathRoundTripsPreserveUnixBytesAndWindowsRules() async throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let service = try await ServerOperationService(root: root.appendingPathComponent("journal"),
            account: OperationAccount(hostIdentity: "host", accountIdentity: "account"))
        let concreteUnix = RemoteFileProvider(hostID: UUID(), rpcClient: AcceptedProviderRPC(service: service),
                                              transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        let unix: any FileProvider = concreteUnix
        let bytes = Data([47, 104, 111, 109, 101, 47, 255, 254])
        let displayed = try await unix.displayLocation(.unix(bytes))
        let roundTrip = try await unix.operationPath(displayed)
        XCTAssertEqual(roundTrip, .unix(bytes))
        let concreteUnixLocation = try await concreteUnix.displayLocation(.unix(bytes))
        let concreteUnixPath = try await concreteUnix.operationPath(concreteUnixLocation)
        XCTAssertEqual(concreteUnixPath, .unix(bytes))
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "unused")
        let concreteWindows = WindowsRemoteProvider(hostID: UUID(), sshTarget: "unused", channel: channel)
        let windows: any FileProvider = concreteWindows
        let native = #"C:\Users\Example\Unicode ü.txt"#
        let windowsLocation = try await windows.displayLocation(.windows(native))
        let windowsRoundTrip = try await windows.operationPath(windowsLocation)
        XCTAssertEqual(windowsRoundTrip, .windows(native))
        let concreteWindowsLocation = try await concreteWindows.displayLocation(.windows(native))
        let concreteWindowsPath = try await concreteWindows.operationPath(concreteWindowsLocation)
        XCTAssertEqual(concreteWindowsPath, .windows(native))
        await channel.disconnect()
    }

    func testTypedLookupKeepsDeniedDisconnectedAndMissingDistinct() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        for expected in [OperationLookup<OperationObservation>.denied, .disconnected, .missing, .unsupported] {
            let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
                guard case .lookup = request else { throw OperationContractError.invalidReceipt }
                return .lookup(expected)
            }, upload: { _, _ in throw OperationContractError.invalidReceipt })
            let coordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
            let observed = try await coordinator.lookup(.unix(Data("/destination".utf8)), hostID: fixture.hostID)
            XCTAssertEqual(observed.result, expected)
            XCTAssertEqual(observed.location.account, fixture.account)
        }
        await fixture.session.disconnect()
    }

    @MainActor
    func testCrossPlatformDestinationNamesPreserveUnicodeAndRejectUnrepresentableNames() throws {
        let windows = try FileOperationQueue.targetPath(source: .unix(Data("/home/é space.txt".utf8)),
            directory: .windows(#"C:\Target"#), index: 2)
        XCTAssertEqual(windows, .windows(#"C:\Target\é space 2.txt"#))
        let unix = try FileOperationQueue.targetPath(source: .windows(#"C:\Source\é space.txt"#), directory: .unix(Data("/target".utf8)))
        XCTAssertEqual(unix, .unix(Data("/target/é space.txt".utf8)))
        for name in [Data([47, 255]), Data("/source/child\\escape".utf8), Data("/source/child:name".utf8)] {
            XCTAssertThrowsError(try FileOperationQueue.targetPath(source: .unix(name), directory: .windows(#"C:\Target"#)))
        }
    }

    func testDestinationCreatedAfterMissingLookupCannotBeOverwritten() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let service = fixture.boundary.service
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { try await service.reply(to: $0) }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let coordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
        let missing = try await coordinator.lookup(try XCTUnwrap(fixture.intent.destination).path, hostID: fixture.hostID)
        XCTAssertEqual(missing.result, .missing)
        try Data("external writer".utf8).write(to: fixture.destination)
        let found = try await coordinator.lookup(missing.location.path, hostID: fixture.hostID)
        guard case .found = found.result else { return XCTFail("Existing destination was not found") }
        _ = try await coordinator.perform(fixture.intent, hostID: fixture.hostID, work: .copy)
        let result = try await coordinator.checkResult(fixture.intent.id)
        XCTAssertEqual(result.outcome, .failedUnchanged)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("external writer".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        await fixture.session.disconnect()
    }
}

struct AcceptedProviderRPC: RemoteRPCClient {
    let service: ServerOperationService
    func send(_ message: RPCMessage) async throws -> [Data] {
        if case .operation(let request) = message { return [try await service.reply(to: request).encoded()] }
        return try RPCHandler(operationService: service).handleChunks(message: ServerRPCMessage(binaryEncoded: message.binaryEncoded()))
    }
}
