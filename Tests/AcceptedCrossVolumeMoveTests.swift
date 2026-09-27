import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class AcceptedCrossVolumeMoveTests: XCTestCase {
    func testActualCrossVolumeMoveCopiesBeforeSourceTrash() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        defer { queue.resetRemoteQueueStateForTesting() }
        let image = fixture.root.appendingPathComponent("volume.sparsebundle")
        let mount = fixture.root.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        try await diskImage(["create", "-quiet", "-size", "64m", "-type", "SPARSEBUNDLE", "-fs", "HFS+",
                             "-volname", "Detours Cross Volume", image.path])
        try await diskImage(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        do {
            let sourceDirectory = try OperationDirectory(path: Data(fixture.root.path.utf8))
            let targetDirectory = try OperationDirectory(path: Data(mount.path.utf8))
            XCTAssertNotEqual(sourceDirectory.identity.volume, targetDirectory.identity.volume)
            let service = fixture.boundary.service
            let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
                request: { try await service.reply(to: $0) }, upload: { _, _ in throw OperationContractError.invalidReceipt })
            let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
                                              transferChannel: RemoteTransferChannel(sshTarget: "unused"))
            queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
            queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
            let locations = try await queue.move(items: [.remote(hostID: fixture.hostID, path: fixture.source.path)],
                                                to: .remote(hostID: fixture.hostID, path: mount.path))
            XCTAssertEqual(locations, [.remote(hostID: fixture.hostID, path: mount.appendingPathComponent("source").path)])
            XCTAssertEqual(try Data(contentsOf: mount.appendingPathComponent("source")), fixture.bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
            let saved = try XCTUnwrap(queue.remoteOperationResults.values.first)
            XCTAssertEqual(saved.items.map { $0.result.intent.action }, [.copy, .trash])
            XCTAssertEqual(saved.items.map(\.outcome), [.committed, .committed])
            XCTAssertEqual(saved.items[1].requiresVerified, [saved.items[0].identity.id])
            XCTAssertEqual(saved.items[1].result.receipt?.sourceDisposition, .confirmed)
            XCTAssertTrue(saved.items[1].result.receipt?.recovery.contains { $0.purpose == .sourceTrash } == true)
            await fixture.session.disconnect()
            try await diskImage(["detach", "-quiet", mount.path])
        } catch {
            await fixture.session.disconnect()
            do { try await diskImage(["detach", "-quiet", mount.path]) } catch { XCTFail("Cross-volume fixture detach failed: \(error)") }
            throw error
        }
    }

    private func diskImage(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let worker = RemoteProcessWorker(process: process)
        let result = try await worker.perform { worker in
            try worker.start()
            worker.closeInput()
            while !(try worker.read(maximumBytes: 4096)).isEmpty {}
            let status = try worker.waitForExit()
            worker.finishDiagnostics()
            return status
        }
        guard result == 0 else {
            throw NSError(domain: "Detours.CrossVolumeFixture", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: worker.diagnostics])
        }
    }
}
