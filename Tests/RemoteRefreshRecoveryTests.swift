import AppKit
import XCTest
@testable import Detours
@testable import detours_server

@MainActor
final class RemoteRefreshRecoveryTests: XCTestCase {
    func testMissingErrorSurvivesRemoteEncoding() {
        let payload = RPCHandler.encodeError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError))
        XCTAssertEqual(SSHRemoteRPCClient.decodeError(payload), .notFound)
    }

    func testMissingErrorKeepsSingleStringWireFormat() throws {
        let payload = RPCHandler.encodeError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
        var reader = ServerRPCBinaryReader(data: payload)
        XCTAssertEqual(try reader.readString(), "notFound")
        XCTAssertNoThrow(try reader.requireComplete())
    }

    func testPermissionErrorIsNotTreatedAsDisappearance() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        XCTAssertFalse(FileOperations.isMissingFileError(error))
        XCTAssertNotEqual(SSHRemoteRPCClient.decodeError(RPCHandler.encodeError(error)), .notFound)
    }

    func testOlderHelperErrorStillDecodes() {
        var writer = RPCBinaryWriter()
        writer.writeString("Connection failed")
        XCTAssertEqual(SSHRemoteRPCClient.decodeError(writer.data), .invalidResponse("Connection failed"))
    }

    func testFileDisappearingAfterEnumerationDoesNotAbortListing() throws {
        let directory = try createTempDirectory()
        defer { cleanupTempDirectory(directory) }
        _ = try createTestFile(in: directory, name: "survivor.txt", content: "keep")
        let payload = try FileOperations(fileManager: DisappearingEntryFileManager())
            .list(path: ServerRemotePath(directory.path), showHidden: false)
        XCTAssertEqual(try RemoteFileProvider.decodeFileEntries(payload).map(\.name), [Data("survivor.txt".utf8)])
    }

    func testMissingListingDirectoryStillFails() throws {
        let directory = try createTempDirectory()
        defer { cleanupTempDirectory(directory) }
        XCTAssertThrowsError(try FileOperations().list(
            path: ServerRemotePath(directory.appendingPathComponent("missing").path), showHidden: false
        )) { error in
            XCTAssertTrue(FileOperations.isMissingFileError(error))
        }
    }

    func testMissingExpandedFolderRefreshesParentAndRemovesStaleRow() async throws {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/root")
        let folder = FileItem(
            name: "missing", location: .remote(hostID: hostID, path: "/root/missing"),
            isDirectory: true, size: nil, dateModified: Date(timeIntervalSince1970: 0), icon: NSImage()
        )
        folder.setChildrenForTesting([])
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        defer { controller.shutdown() }
        controller.currentRemoteLocation = root
        let rpc = MissingBranchRPCClient()
        controller.currentRemoteProvider = RemoteFileProvider(
            hostID: hostID, rpcClient: rpc,
            transferChannel: RemoteTransferChannel(sshTarget: "unused")
        )
        controller.dataSource.displayedRootLocation = root
        controller.dataSource.applier.setRootItems([folder])
        controller.dataSource.applier.reloadAll()
        controller.refreshScheduler.submitListingRefresh(directory: folder.location, cause: .watcher)

        let deadline = Date().addingTimeInterval(2)
        while !controller.dataSource.items.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(controller.dataSource.items.isEmpty)
        XCTAssertNil(controller.remoteRefreshErrorBanner)
        let paths = await rpc.listedPaths
        XCTAssertEqual(paths, ["/root/missing", "/root"])
    }

    func testLongMultilineErrorStaysAboveListingAndRetryStaysCompact() throws {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        defer { controller.shutdown() }
        controller.view.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        controller.showRemoteRefreshError(
            directory: .remote(hostID: UUID(), path: "/folder\nname"),
            error: RemoteFileProviderError.invalidResponse(String(repeating: "raw\nerror ", count: 100))
        )
        controller.view.layoutSubtreeIfNeeded()
        let banner = try XCTUnwrap(controller.remoteRefreshErrorBanner)
        let label = try XCTUnwrap(banner.subviews.compactMap { $0 as? NSTextField }.first)
        let retry = try XCTUnwrap(banner.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(label.stringValue, "Could not refresh this folder. Try again.")
        XCTAssertEqual(label.maximumNumberOfLines, 1)
        XCTAssertEqual(banner.frame.height, 32)
        XCTAssertFalse(banner.frame.intersects(controller.scrollView.frame))
        XCTAssertLessThan(retry.frame.width, 90)
        XCTAssertTrue(banner.bounds.contains(label.frame))
        controller.hideRemoteRefreshError()
        XCTAssertEqual(controller.scrollViewTopConstraint?.constant, 0)
    }

    func testTransientWatcherFailureRecoversWithoutManualRefresh() async throws {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        defer { controller.shutdown() }
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/root")
        let rpc = MissingBranchRPCClient(failuresRemaining: 1)
        controller.currentRemoteLocation = root
        controller.dataSource.displayedRootLocation = root
        controller.currentRemoteProvider = RemoteFileProvider(
            hostID: hostID, rpcClient: rpc, transferChannel: RemoteTransferChannel(sshTarget: "unused")
        )
        controller.refreshScheduler.submitListingRefresh(directory: root, cause: .watcher)
        let deadline = Date().addingTimeInterval(2)
        while await rpc.listedPaths.count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        while controller.refreshScheduler.isRefreshInFlight && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let paths = await rpc.listedPaths
        XCTAssertEqual(paths, ["/root", "/root"])
        XCTAssertNil(controller.remoteRefreshErrorBanner)
        XCTAssertTrue(controller.remoteRefreshRecoveryTasks.isEmpty)
    }

    func testReconnectRestartsWatchAndReloadsWithoutManualRefresh() async throws {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        defer { controller.shutdown() }
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/root")
        let rpc = MissingBranchRPCClient()
        controller.currentRemoteLocation = root
        controller.dataSource.displayedRootLocation = root
        controller.currentRemoteProvider = RemoteFileProvider(
            hostID: hostID, rpcClient: rpc, transferChannel: RemoteTransferChannel(sshTarget: "unused"),
            watcherClient: RemoteWatcherClient(hostID: hostID, rpcClient: rpc)
        )

        controller.recoverRemoteListingAfterReconnect()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let listed = await rpc.listedPaths
            if controller.providerWatches[root] != nil, !listed.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(controller.providerWatches[root])
        let paths = await rpc.listedPaths
        XCTAssertEqual(paths, ["/root"])
    }
}

private final class DisappearingEntryFileManager: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        try super.contentsOfDirectory(atPath: path) + ["vanished.txt"]
    }
}

private actor MissingBranchRPCClient: RemoteRPCClient {
    var listedPaths: [String] = []
    var failuresRemaining: Int

    init(failuresRemaining: Int = 0) { self.failuresRemaining = failuresRemaining }

    func send(_ message: RPCMessage) async throws -> [Data] {
        guard case .list(let path, _) = message else { return [] }
        listedPaths.append(path.lossyDisplayString)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw RemoteFileProviderError.invalidResponse("Transient connection failure")
        }
        if path.lossyDisplayString == "/root/missing" {
            throw RemoteFileProviderError.notFound
        }
        return [RemoteFileProvider.encodeFileEntries([])]
    }
}
