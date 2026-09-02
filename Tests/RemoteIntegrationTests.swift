import AppKit
import XCTest
@testable import Detours

final class RemoteIntegrationTests: XCTestCase {
    static var linuxTestTarget: String {
        ProcessInfo.processInfo.environment["DETOURS_LINUX_TEST_TARGET"]
            ?? ProcessInfo.processInfo.environment["LINUX_TARGET"]
            ?? "devtest"
    }

    static var intelMacTestTarget: String {
        ProcessInfo.processInfo.environment["DETOURS_INTEL_MAC_TEST_TARGET"]
            ?? ProcessInfo.processInfo.environment["INTEL_MAC_TARGET"]
            ?? "wraith"
    }

    func testListDirectoryReturnsExpectedEntries() async throws {
        let session = try await RemoteIntegrationSession.make()

        let started = Date()
        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: "/etc"), showHidden: false)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(entries.contains { $0.name == "hosts" })
    }

    func testListChunksAndQuickLookCrossRealSSHHelperBoundary() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH(
            "printf preview-body > \(Self.shellQuote(remoteRoot + "/preview.txt")); "
                + "mkdir \(Self.shellQuote(remoteRoot + "/folder")); "
                + "truncate -s \(RemoteFileCache.quickLookMaximumBytes + 1) "
                + Self.shellQuote(remoteRoot + "/too-large.bin")
        )
        let root = Location.remote(hostID: session.hostID, path: remoteRoot)
        var names: Set<String> = []

        for try await chunk in await session.provider.listChunks(root, showHidden: true) {
            names.formUnion(chunk.map(\.name))
            XCTAssertTrue(chunk.allSatisfy { entry in
                guard case .remote(let hostID, _) = entry.location else { return false }
                return hostID == session.hostID
            })
        }
        let quickLookURL = try await session.provider.openForQuickLook(
            root.appendingPathComponent("preview.txt")
        )
        defer { try? FileManager.default.removeItem(at: quickLookURL.deletingLastPathComponent()) }

        XCTAssertEqual(names, ["folder", "preview.txt", "too-large.bin"])
        XCTAssertEqual(try String(contentsOf: quickLookURL, encoding: .utf8), "preview-body")

        do {
            _ = try await session.provider.openForQuickLook(root.appendingPathComponent("too-large.bin"))
            XCTFail("Expected real remote Quick Look size rejection")
        } catch FileProviderError.unsupportedOperation(let message) {
            XCTAssertTrue(message.contains("100 MB"))
        }
    }

    @MainActor
    func testSymlinkQuickLookResolvesAndDownloadsTheLinkedFileThroughTheRealHelper() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH(
            "mkdir \(Self.shellQuote(remoteRoot + "/releases")) \(Self.shellQuote(remoteRoot + "/builds")); "
                + "printf linked-body > \(Self.shellQuote(remoteRoot + "/releases/config.yaml")); "
                + "ln -s releases/config.yaml \(Self.shellQuote(remoteRoot + "/current")); "
                + "ln -s builds \(Self.shellQuote(remoteRoot + "/latest"))"
        )
        let root = Location.remote(hostID: session.hostID, path: remoteRoot)
        let entries = try await session.provider.list(root, showHidden: true)
        guard let fileLink = entries.first(where: { $0.name == "current" }),
              let folderLink = entries.first(where: { $0.name == "latest" }) else {
            XCTFail("Expected both symlinks in the listing: \(entries.map(\.name))")
            return
        }
        XCTAssertTrue(fileLink.isSymbolicLink)
        XCTAssertFalse(fileLink.isDirectory, "A link to a file must enter the remote Quick Look path")

        let viewController = FileListViewController()
        let fileSource = try await viewController.resolveRemoteQuickLookSource(
            for: FileItem(entry: fileLink, icon: NSImage()),
            provider: session.provider
        )
        XCTAssertEqual(fileSource.location.path, remoteRoot + "/releases/config.yaml")
        XCTAssertEqual(fileSource.name, "config.yaml")
        XCTAssertEqual(fileSource.entry.fileSize, 11)

        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-symlink-quicklook-\(UUID().uuidString)")
            .appendingPathComponent("config.yaml")
        defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
        try await session.provider.download(fileSource.location, to: downloaded)
        XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), "linked-body")

        let folderSource = try await viewController.resolveRemoteQuickLookSource(
            for: FileItem(entry: folderLink, icon: NSImage()),
            provider: session.provider
        )
        XCTAssertEqual(folderSource.location.path, remoteRoot + "/builds")
        XCTAssertTrue(folderSource.entry.isDirectory || folderSource.entry.fileSize == nil, "A link to a folder must be declined, not previewed as an empty file")
    }

    func testArchiveWrongPasswordMapsRealHelperErrorToRetry() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf secret > \(Self.shellQuote(remoteRoot + "/secret.txt"))")
        let archive = try await session.provider.archiveCreate(
            [.remote(hostID: session.hostID, path: remoteRoot + "/secret.txt")],
            format: .zip,
            archiveName: "encrypted",
            password: "correct-password"
        )

        do {
            _ = try await session.provider.archiveExtract(
                archive,
                password: "wrong-password"
            )
            XCTFail("Expected archive password retry")
        } catch FileOperationError.archivePasswordRequired {
            // The real helper's wrong-password error must retain the provider-level retry contract.
        }
    }

    func testCopyRemoteToLocal() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf remote-body > \(Self.shellQuote(remoteRoot + "/remote.txt"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = localRoot.appendingPathComponent("remote.txt")

        try await session.provider.download(.remote(hostID: session.hostID, path: remoteRoot + "/remote.txt"), to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "remote-body")
    }

    func testCopyLocalToRemote() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let source = try createTestFile(in: localRoot, name: "upload.txt", content: "local-body")

        try await session.provider.upload(source, to: .remote(hostID: session.hostID, path: remoteRoot + "/upload.txt"))
        let entry = try await session.provider.stat(.remote(hostID: session.hostID, path: remoteRoot + "/upload.txt"))

        XCTAssertEqual(entry.fileSize, 10)
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(remoteRoot + "/upload.txt"))"), "local-body")
    }

    func testRemoteProviderCopyUsesRealHelperProtocol() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH(
            "mkdir \(Self.shellQuote(remoteRoot + "/destination")); "
                + "printf rpc-copy > \(Self.shellQuote(remoteRoot + "/source.txt"))"
        )
        let source = Location.remote(hostID: session.hostID, path: remoteRoot + "/source.txt")
        let destination = Location.remote(hostID: session.hostID, path: remoteRoot + "/destination")

        let copied = try await session.provider.copy([source], to: destination)

        let expected = destination.appendingPathComponent("source.txt")
        XCTAssertEqual(copied, [expected])
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(expected.path))"), "rpc-copy")
    }

    @MainActor
    func testFileOperationQueueCopiesRemoteFileToLocalFilesystem() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf remote-payload > \(Self.shellQuote(remoteRoot + "/remote.txt"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = try createTestFolder(in: localRoot, name: "destination")
        let source = Location.remote(hostID: session.hostID, path: remoteRoot + "/remote.txt")
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(session.provider, for: session.hostID)
        defer { queue.unregisterRemoteFileProvider(for: session.hostID) }

        let copied = try await queue.copy(items: [source], to: .local(destination))

        let localCopy = destination.appendingPathComponent("remote.txt")
        XCTAssertEqual(copied, [.local(localCopy)])
        XCTAssertEqual(try String(contentsOf: localCopy, encoding: .utf8), "remote-payload")
        XCTAssertTrue(try Self.remotePathExists(source.path))
    }

    @MainActor
    func testFileOperationQueueCopiesLocalFileToRemoteFilesystem() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("mkdir \(Self.shellQuote(remoteRoot + "/destination"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let source = try createTestFile(in: localRoot, name: "local.txt", content: "local-payload")
        let destination = Location.remote(hostID: session.hostID, path: remoteRoot + "/destination")
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(session.provider, for: session.hostID)
        defer { queue.unregisterRemoteFileProvider(for: session.hostID) }

        let copied = try await queue.copy(items: [.local(source)], to: destination)

        let remoteCopy = destination.appendingPathComponent("local.txt")
        XCTAssertEqual(copied, [remoteCopy])
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(remoteCopy.path))"), "local-payload")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "local-payload")
    }

    @MainActor
    func testFileOperationQueueMovesRemoteFileToLocalFilesystem() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf move-payload > \(Self.shellQuote(remoteRoot + "/move.txt"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = try createTestFolder(in: localRoot, name: "destination")
        let source = Location.remote(hostID: session.hostID, path: remoteRoot + "/move.txt")
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(session.provider, for: session.hostID)
        defer { queue.unregisterRemoteFileProvider(for: session.hostID) }

        let moved = try await queue.move(items: [source], to: .local(destination))

        let localCopy = destination.appendingPathComponent("move.txt")
        XCTAssertEqual(moved, [.local(localCopy)])
        XCTAssertEqual(try String(contentsOf: localCopy, encoding: .utf8), "move-payload")
        XCTAssertFalse(try Self.remotePathExists(source.path))
        let trashInfo = try Self.runSSH(
            "grep -lFx \(Self.shellQuote("Path=\(source.path)")) "
                + "\"$HOME/.local/share/Trash/info/\"*.trashinfo 2>/dev/null | head -n 1"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let trashInfoPath = try XCTUnwrap(trashInfo.isEmpty ? nil : trashInfo)

        _ = try await session.provider.restoreFromTrash([
            TrashedItem(
                originalLocation: source,
                trashLocation: .remote(hostID: session.hostID, path: trashInfoPath)
            ),
        ])
        XCTAssertTrue(try Self.remotePathExists(source.path))
    }

    @MainActor
    func testFileOperationQueueRemoteDeleteUndoRestoresRealFile() async throws {
        RemoteTrashExplainer.markDismissed()
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf undo-payload > \(Self.shellQuote(remoteRoot + "/undo.txt"))")
        let item = Location.remote(hostID: session.hostID, path: remoteRoot + "/undo.txt")
        let queue = FileOperationQueue.shared
        let undoManager = UndoManager()
        queue.registerRemoteFileProvider(session.provider, for: session.hostID)
        defer { queue.unregisterRemoteFileProvider(for: session.hostID) }

        try await queue.delete(items: [item], undoManager: undoManager)
        XCTAssertFalse(try Self.remotePathExists(item.path))
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        try await Self.waitForRemotePath(item.path)

        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(item.path))"), "undo-payload")
    }

    @MainActor
    func testFileOperationQueueRemoteRenameUsesRealProvider() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf rename-payload > \(Self.shellQuote(remoteRoot + "/old.txt"))")
        let item = Location.remote(hostID: session.hostID, path: remoteRoot + "/old.txt")
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(session.provider, for: session.hostID)
        defer { queue.unregisterRemoteFileProvider(for: session.hostID) }

        let renamed = try await queue.rename(item: item, to: "new.txt")

        XCTAssertEqual(renamed, .remote(hostID: session.hostID, path: remoteRoot + "/new.txt"))
        XCTAssertFalse(try Self.remotePathExists(item.path))
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(renamed.path))"), "rename-payload")
    }

    func testServerDeployerUploadsAndAtomicallyFinalizesRealRemoteBinary() async throws {
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let bundle = try createTestFile(in: localRoot, name: "detours-server", content: "deployed-helper")
        let installDirectory = remoteRoot + "/install"
        let deployer = ServerDeployer(
            client: SSHServerDeploymentClient(sshTarget: Self.linuxTestTarget),
            bundledBinaryURL: bundle,
            installDirectory: installDirectory
        )

        let result = try await deployer.deployIfNeeded()

        let finalPath = installDirectory + "/detours-server"
        XCTAssertEqual(result, ServerDeploymentResult(deployed: true, reason: .missing))
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(finalPath))"), "deployed-helper")
        XCTAssertEqual(
            try Self.runSSH("stat -c '%a' \(Self.shellQuote(finalPath))").trimmingCharacters(in: .whitespacesAndNewlines),
            "700"
        )
        XCTAssertFalse(try Self.remotePathExists(finalPath + ".tmp"))
    }

    func testServerDeployerRemovesRealSCPPartialAfterRemoteFinalizeFailureAndRetries() async throws {
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let bundle = try createTestFile(in: localRoot, name: "detours-server", content: "retry-helper")
        let installDirectory = remoteRoot + "/install"
        let baseClient = SSHServerDeploymentClient(sshTarget: Self.linuxTestTarget)
        let failingDeployer = ServerDeployer(
            client: FailingFinalizationSSHDeploymentClient(base: baseClient),
            bundledBinaryURL: bundle,
            installDirectory: installDirectory
        )

        do {
            _ = try await failingDeployer.deployIfNeeded()
            XCTFail("Expected real remote finalization to fail")
        } catch let error as ServerDeployerError {
            guard case .commandFailed = error else {
                XCTFail("Expected commandFailed, got \(error)")
                return
            }
        }
        XCTAssertFalse(try Self.remotePathExists(installDirectory + "/detours-server.tmp"))

        let retry = try await ServerDeployer(
            client: baseClient,
            bundledBinaryURL: bundle,
            installDirectory: installDirectory
        ).deployIfNeeded()

        XCTAssertEqual(retry, ServerDeploymentResult(deployed: true, reason: .missing))
        XCTAssertEqual(
            try Self.runSSH("cat \(Self.shellQuote(installDirectory + "/detours-server"))"),
            "retry-helper"
        )
        XCTAssertFalse(try Self.remotePathExists(installDirectory + "/detours-server.tmp"))
    }

    func testPersistentRPCClientRoutesConcurrentMultiChunkResponsesByRequestID() async throws {
        try Self.runSSH("test -x ~/.detours-server/detours-server")
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH(
            "i=0; while [ $i -lt 1001 ]; do : > \(Self.shellQuote(remoteRoot))/item-$i; i=$((i+1)); done; "
                + "printf first > \(Self.shellQuote(remoteRoot + "/first.txt")); "
                + "printf second > \(Self.shellQuote(remoteRoot + "/second.txt"))"
        )
        let controlRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("dtssh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { cleanupTempDirectory(controlRoot) }
        let hostID = UUID()
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: hostID, sshTarget: Self.linuxTestTarget),
            controlDirectory: controlRoot.appendingPathComponent("ssh", isDirectory: true),
            hostTrust: SSHHostTrust(
                knownHostsURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
            )
        )
        let rpcClient = SSHRemoteRPCClient(connection: connection)
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: rpcClient,
            transferChannel: RemoteTransferChannel(sshTarget: Self.linuxTestTarget, controlDirectory: controlRoot)
        )
        let root = Location.remote(hostID: hostID, path: remoteRoot)

        try await connection.connect()
        let values: ([LoadedFileEntry], LoadedFileEntry, LoadedFileEntry, [Data])
        do {
            async let entries = provider.list(root, showHidden: true)
            async let first = provider.stat(root.appendingPathComponent("first.txt"))
            async let second = provider.stat(root.appendingPathComponent("second.txt"))
            async let version = rpcClient.send(.protocolVersion(1))
            values = try await (entries, first, second, version)
        } catch {
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()

        var versionReader = RPCBinaryReader(data: try XCTUnwrap(values.3.first))
        XCTAssertEqual(try versionReader.readInt64(), 1)
        try versionReader.requireComplete()
        XCTAssertEqual(values.0.count, 1_003)
        XCTAssertEqual(values.1.name, "first.txt")
        XCTAssertEqual(values.2.name, "second.txt")
    }

    func testCancellingPendingRealRPCDoesNotConsumeNextResponse() async throws {
        try Self.runSSH("test -x ~/.detours-server/detours-server")
        let controlRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("dtssh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { cleanupTempDirectory(controlRoot) }
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: Self.linuxTestTarget),
            controlDirectory: controlRoot.appendingPathComponent("ssh", isDirectory: true),
            hostTrust: SSHHostTrust(
                knownHostsURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
            )
        )
        let client = SSHRemoteRPCClient(connection: connection)
        try await connection.connect()
        do {
            let impossibleQuery = Data("detours-no-match-\(UUID().uuidString)".utf8)
            let pending = Task {
                try await client.send(.find(query: impossibleQuery, cap: Int64.max))
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            let cancelledAt = Date()
            pending.cancel()

            do {
                _ = try await pending.value
                XCTFail("Expected the pending real RPC to be cancelled")
            } catch is CancellationError {
                XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
            }

            let response = try await client.send(.protocolVersion(1))
            var reader = RPCBinaryReader(data: try XCTUnwrap(response.first))
            XCTAssertEqual(try reader.readInt64(), 1)
            try reader.requireComplete()
        } catch {
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()
    }

    func testUnixHostKindProbeUsesRealSSHProcessAndPowerShellFailure() async throws {
        _ = try Self.runSSH("uname -s", target: Self.linuxTestTarget)

        let kind = await RemoteHostKindProbe(
            client: SSHRemoteHostKindProbeClient(sshTarget: Self.linuxTestTarget)
        ).probe()

        XCTAssertEqual(kind, .unix)
    }

    @MainActor
    func testRemoteOpenWithSessionUploadsBackToRealRemoteFile() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf original > \(Self.shellQuote(remoteRoot + "/notes.md"))")
        let location = Location.remote(hostID: session.hostID, path: remoteRoot + "/notes.md")
        var openedURL: URL?

        let openSession = try await FileOpenHelper.prepareRemoteOpenWith(
            location: location,
            provider: session.provider,
            hostID: session.hostID,
            opener: { openedURL = $0 }
        )

        XCTAssertEqual(openedURL?.lastPathComponent, "notes.md")
        XCTAssertEqual(try String(contentsOf: openSession.localURL, encoding: .utf8), "original")

        try Data("edited".utf8).write(to: openSession.localURL)
        let choice = try await FileOpenHelper.finishRemoteOpenWith(openSession, provider: session.provider) { _ in
            XCTFail("Unexpected remote conflict")
            return .cancel
        }

        XCTAssertNil(choice)
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(remoteRoot + "/notes.md"))"), "edited")
    }

    /// A large upload whose destination folder does not exist makes the helper fail before it
    /// reads the body. The app must report that as an error, not die writing into the dead pipe.
    func testLargeUploadIntoMissingRemoteFolderReportsAnErrorInsteadOfDying() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let source = localRoot.appendingPathComponent("large.bin")
        try Data(count: 4 * 1_024 * 1_024).write(to: source)
        let destination = Location.remote(hostID: session.hostID, path: remoteRoot + "/missing/large.bin")

        do {
            try await session.provider.upload(source, to: destination)
            XCTFail("Uploading into a missing folder must fail")
        } catch let error as RemoteTransferError {
            guard case .processFailed = error else {
                XCTFail("Unexpected transfer error: \(error)")
                return
            }
        }

        let names = try await session.provider.list(.remote(hostID: session.hostID, path: remoteRoot), showHidden: true)
            .map(\.name)
        XCTAssertEqual(names, [], "The failed upload must leave nothing behind")
    }

    func testLargeUploadWithSpacesInTheNameIntoANestedFolderSucceeds() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("mkdir -p \(Self.shellQuote(remoteRoot + "/2026-09-01T1028/report"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let name = "OSAI-OS-549575-Exam-Report Best Practice.pdf"
        let source = localRoot.appendingPathComponent(name)
        try Data(count: 3 * 1_024 * 1_024).write(to: source)
        let destination = Location.remote(hostID: session.hostID, path: remoteRoot + "/2026-09-01T1028/report/" + name)

        try await session.provider.upload(source, to: destination)

        let entry = try await session.provider.stat(destination)
        XCTAssertEqual(entry.fileSize, 3 * 1_024 * 1_024)
    }

    func testLargeTransferUsesRemoteTransferChannel() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("dd if=/dev/zero of=\(Self.shellQuote(remoteRoot + "/large.bin")) bs=1M count=100 status=none")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = localRoot.appendingPathComponent("large.bin")

        let download = Task {
            try await session.provider.download(.remote(hostID: session.hostID, path: remoteRoot + "/large.bin"), to: destination)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: "/etc"), showHidden: false)

        try await download.value
        let size = try XCTUnwrap(destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(size, 100 * 1_024 * 1_024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RemoteTransferChannel.partialURL(for: destination).path))
        XCTAssertTrue(entries.contains { $0.name == "hosts" })
    }

    func testWatchDirectoryReceivesInotifyEvent() async throws {
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        let session = try PersistentRemoteRPCSession.start()
        defer { session.close() }
        let token = UUID()

        try session.send(.watch(path: RemotePath(remoteRoot), token: token), id: 1)
        _ = try session.waitForEnvelope(timeout: 2) { envelope in
            envelope.id == 1 && envelope.kind == .response
        }

        try Self.runSSH("printf watched > \(Self.shellQuote(remoteRoot + "/watched.txt"))")
        let envelope = try session.waitForEnvelope(timeout: 2) { envelope in
            envelope.kind == .event && envelope.messageType == "WatchEvent"
        }
        let message = try RPCMessage(binaryEncoded: envelope.payload)

        guard case .watchEvent(let watch, _, let path) = message else {
            XCTFail("Expected WatchEvent")
            return
        }
        XCTAssertEqual(watch, token)
        XCTAssertEqual(path, RemotePath(remoteRoot + "/watched.txt"))
    }

    func testTrashAndRestore() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("printf trash > \(Self.shellQuote(remoteRoot + "/trash.txt"))")
        let location = Location.remote(hostID: session.hostID, path: remoteRoot + "/trash.txt")

        let trashed = try await session.provider.trash([location])
        XCTAssertFalse(try Self.remotePathExists(remoteRoot + "/trash.txt"))
        let restored = try await session.provider.restoreFromTrash(trashed)

        XCTAssertEqual(restored, [location])
        XCTAssertTrue(try Self.remotePathExists(remoteRoot + "/trash.txt"))
    }

    func testGitStatusOverlay() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH(
            """
            cd \(Self.shellQuote(remoteRoot)); \
            git init >/dev/null; \
            git config user.email detours@example.test; \
            git config user.name 'Detours Tests'; \
            printf one > tracked.txt; \
            git add tracked.txt; \
            git commit -m initial >/dev/null; \
            printf two > tracked.txt
            """
        )

        let statuses = await session.provider.gitStatus(for: .remote(hostID: session.hostID, path: remoteRoot))

        XCTAssertEqual(statuses[.remote(hostID: session.hostID, path: remoteRoot + "/tracked.txt")], .modified)
    }

    func testSymlinkFollowsResolvable() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH("mkdir -p \(Self.shellQuote(remoteRoot + "/target")); ln -s target \(Self.shellQuote(remoteRoot + "/link"))")

        let target = try await session.provider.readSymlink(.remote(hostID: session.hostID, path: remoteRoot + "/link"))

        XCTAssertEqual(target, .remote(hostID: session.hostID, path: remoteRoot + "/target"))
    }

    func testPermissionDeniedRendersLockBadge() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer {
            _ = try? Self.runSSH("chmod -R u+rwX \(Self.shellQuote(remoteRoot))")
            Self.cleanupRemote(remoteRoot)
        }
        try Self.runSSH("printf secret > \(Self.shellQuote(remoteRoot + "/secret.txt")); chmod 000 \(Self.shellQuote(remoteRoot + "/secret.txt"))")

        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: remoteRoot), showHidden: false)

        let secret = try XCTUnwrap(entries.first { $0.name == "secret.txt" })
        XCTAssertFalse(secret.isReadable)
    }

    func testReconnectAfterIdle() async throws {
        try Self.runSSH("test -x ~/.detours-server/detours-server")
        let hostID = UUID()
        let controlRoot = URL(fileURLWithPath: "/tmp").appendingPathComponent("dtssh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let controlDirectory = controlRoot.appendingPathComponent("ssh", isDirectory: true)
        defer { cleanupTempDirectory(controlRoot) }
        let userKnownHosts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: hostID, sshTarget: Self.linuxTestTarget),
            controlDirectory: controlDirectory,
            hostTrust: SSHHostTrust(knownHostsURL: userKnownHosts),
            idleTimeout: 0.05
        )
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: SSHRemoteRPCClient(connection: connection),
            transferChannel: RemoteTransferChannel(sshTarget: Self.linuxTestTarget, controlDirectory: controlDirectory)
        )

        try await connection.connect()
        await connection.setActivePaneCount(0)
        try await Task.sleep(nanoseconds: 150_000_000)
        let disconnectedForIdle = await connection.isDisconnectedForIdleForTesting()
        await connection.setActivePaneCount(1)
        let entries: [LoadedFileEntry]
        do {
            entries = try await provider.list(.remote(hostID: hostID, path: "/etc"), showHidden: false)
        } catch {
            let state = await connection.state
            let idle = await connection.isDisconnectedForIdleForTesting()
            let stderr = await connection.lastStderrForTesting()
            XCTFail("list after idle failed with \(error), state: \(state), disconnectedForIdle: \(idle), stderr: \(stderr)")
            await connection.disconnect()
            return
        }
        await connection.disconnect()

        XCTAssertTrue(disconnectedForIdle)
        XCTAssertTrue(entries.contains { $0.name == "hosts" })
    }

    @MainActor
    func testHostKeyChangeBlocks() throws {
        let defaults = try Self.makeDefaults()
        let store = RemoteHostStore(defaults: defaults)
        let host = store.add(displayName: "Qualification Linux", sshTarget: Self.linuxTestTarget)
        store.updateFingerprint(id: host.id, fingerprint: "SHA256:old")

        let evaluation = SSHHostTrust().evaluateFingerprint("SHA256:new", for: host.id, in: store)

        XCTAssertEqual(evaluation, .changed(old: "SHA256:old", new: "SHA256:new"))
        XCTAssertEqual(store.host(id: host.id)?.knownHostKeyFingerprint, "SHA256:old")
    }

    func testUnsupportedArchitectureError() async throws {
        let bundleRoot = try createTempDirectory()
        defer { cleanupTempDirectory(bundleRoot) }
        let bundle = try createTestFile(in: bundleRoot, name: "detours-server", content: "server")
        let client = IntegrationDeploymentClient(
            architecture: RemoteArchitecture(system: "Linux", machine: "aarch64")
        )
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        do {
            _ = try await deployer.deployIfNeeded()
            XCTFail("Expected unsupported architecture")
        } catch let error as UnsupportedArchitectureError {
            XCTAssertEqual(error, UnsupportedArchitectureError(system: "Linux", machine: "aarch64"))
            let didUpload = await client.didUpload
            XCTAssertFalse(didUpload)
        }
    }

    func testIntelMacListDirectoryReturnsExpectedEntries() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let home = try Self.remoteHome(target: Self.intelMacTestTarget)

        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: home), showHidden: false)

        XCTAssertFalse(entries.isEmpty)
    }

    func testIntelMacPersistentSSHConnectionListsHome() async throws {
        try await RemoteIntegrationSession.deployIntelMacHelper()
        let temp = URL(fileURLWithPath: "/tmp").appendingPathComponent("dtssh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { cleanupTempDirectory(temp) }
        let hostID = UUID()
        let knownHostsURL = temp.appendingPathComponent("known_hosts")
        let controlDirectory = temp.appendingPathComponent("ssh", isDirectory: true)
        let trust = SSHHostTrust(knownHostsURL: knownHostsURL)
        let hostKey = try await trust.scanHostKey(for: Self.intelMacTestTarget)
        try trust.recordTrustedHostKey(hostKey, hostID: hostID)
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: hostID, sshTarget: Self.intelMacTestTarget),
            controlDirectory: controlDirectory,
            hostTrust: trust
        )
        let rpcClient = SSHRemoteRPCClient(connection: connection)
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: rpcClient,
            transferChannel: RemoteTransferChannel(sshTarget: Self.intelMacTestTarget, controlDirectory: controlDirectory)
        )
        let home = try Self.remoteHome(target: Self.intelMacTestTarget)

        try await connection.connect()
        let response: [Data]
        let entries: [LoadedFileEntry]
        do {
            response = try await rpcClient.send(.protocolVersion(1))
            entries = try await provider.list(.remote(hostID: hostID, path: home), showHidden: false)
        } catch {
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()

        XCTAssertEqual(response.count, 1)
        XCTAssertFalse(entries.isEmpty)
    }

    func testIntelMacCopyRemoteToLocal() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: Self.intelMacTestTarget)
        defer { Self.cleanupRemote(remoteRoot, target: Self.intelMacTestTarget) }
        try Self.runSSH("printf remote-body > \(Self.shellQuote(remoteRoot + "/remote.txt"))", target: Self.intelMacTestTarget)
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = localRoot.appendingPathComponent("remote.txt")

        try await session.provider.download(.remote(hostID: session.hostID, path: remoteRoot + "/remote.txt"), to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "remote-body")
    }

    func testIntelMacCopyLocalToRemote() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: Self.intelMacTestTarget)
        defer { Self.cleanupRemote(remoteRoot, target: Self.intelMacTestTarget) }
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let source = try createTestFile(in: localRoot, name: "upload.txt", content: "local-body")

        try await session.provider.upload(source, to: .remote(hostID: session.hostID, path: remoteRoot + "/upload.txt"))
        let entry = try await session.provider.stat(.remote(hostID: session.hostID, path: remoteRoot + "/upload.txt"))

        XCTAssertEqual(entry.fileSize, 10)
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(remoteRoot + "/upload.txt"))", target: Self.intelMacTestTarget), "local-body")
    }

    func testIntelMacLargeTransferUsesRemoteTransferChannel() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: Self.intelMacTestTarget)
        defer { Self.cleanupRemote(remoteRoot, target: Self.intelMacTestTarget) }
        try Self.runSSH("dd if=/dev/zero of=\(Self.shellQuote(remoteRoot + "/large.bin")) bs=1m count=100 2>/dev/null", target: Self.intelMacTestTarget)
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let destination = localRoot.appendingPathComponent("large.bin")
        let home = try Self.remoteHome(target: Self.intelMacTestTarget)

        let download = Task {
            try await session.provider.download(.remote(hostID: session.hostID, path: remoteRoot + "/large.bin"), to: destination)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let entries = try await session.provider.list(.remote(hostID: session.hostID, path: home), showHidden: false)

        try await download.value
        let size = try XCTUnwrap(destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(size, 100 * 1_024 * 1_024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RemoteTransferChannel.partialURL(for: destination).path))
        XCTAssertFalse(entries.isEmpty)
    }

    func testIntelMacWatchDirectoryReceivesDarwinEvent() async throws {
        _ = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: Self.intelMacTestTarget)
        defer { Self.cleanupRemote(remoteRoot, target: Self.intelMacTestTarget) }
        let session = try PersistentRemoteRPCSession.start(sshTarget: Self.intelMacTestTarget)
        defer { session.close() }
        let token = UUID()

        try session.send(.watch(path: RemotePath(remoteRoot), token: token), id: 1)
        _ = try session.waitForEnvelope(timeout: 2) { envelope in
            envelope.id == 1 && envelope.kind == .response
        }

        try Self.runSSH("printf watched > \(Self.shellQuote(remoteRoot + "/watched.txt"))", target: Self.intelMacTestTarget)
        let envelope = try session.waitForEnvelope(timeout: 2) { envelope in
            envelope.kind == .event && envelope.messageType == "WatchEvent"
        }
        let message = try RPCMessage(binaryEncoded: envelope.payload)

        guard case .watchEvent(let watch, _, _) = message else {
            XCTFail("Expected WatchEvent")
            return
        }
        XCTAssertEqual(watch, token)
    }

    func testIntelMacTrashAndRestore() async throws {
        let session = try await RemoteIntegrationSession.makeIntelMac()
        let remoteRoot = try Self.makeRemoteFixtureRoot(target: Self.intelMacTestTarget)
        defer { Self.cleanupRemote(remoteRoot, target: Self.intelMacTestTarget) }
        try Self.runSSH("printf trash > \(Self.shellQuote(remoteRoot + "/trash.txt"))", target: Self.intelMacTestTarget)
        let location = Location.remote(hostID: session.hostID, path: remoteRoot + "/trash.txt")

        let trashed = try await session.provider.trash([location])
        XCTAssertFalse(try Self.remotePathExists(remoteRoot + "/trash.txt", target: Self.intelMacTestTarget))
        let restored = try await session.provider.restoreFromTrash(trashed)

        XCTAssertEqual(restored, [location])
        XCTAssertTrue(try Self.remotePathExists(remoteRoot + "/trash.txt", target: Self.intelMacTestTarget))
    }

    func testIntelMacUnsupportedArmFixture() async throws {
        let bundleRoot = try createTempDirectory()
        defer { cleanupTempDirectory(bundleRoot) }
        let bundle = try createTestFile(in: bundleRoot, name: "detours-server", content: "server")
        let client = IntegrationDeploymentClient(
            architecture: RemoteArchitecture(system: "Darwin", machine: "arm64")
        )
        let deployer = ServerDeployer(client: client, bundledBinaryURL: bundle)

        do {
            _ = try await deployer.deployIfNeeded()
            XCTFail("Expected unsupported architecture")
        } catch let error as UnsupportedArchitectureError {
            XCTAssertEqual(error, UnsupportedArchitectureError(system: "Darwin", machine: "arm64"))
            XCTAssertTrue(error.localizedDescription.contains("x86_64 macOS"))
            let didUpload = await client.didUpload
            XCTAssertFalse(didUpload)
        }
    }

    func testSymlinkBrokenShowsError() {
        let message = FileListViewController.remoteBrokenSymlinkMessage(fileName: "missing-link")

        XCTAssertEqual(message, "Remote symbolic link \"missing-link\" is broken or unreachable")
    }

    func testSameHostCopyAndMoveThroughRealHelper() async throws {
        let session = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH(
            "mkdir \(Self.shellQuote(remoteRoot + "/copy-destination")) "
                + "\(Self.shellQuote(remoteRoot + "/move-destination")); "
                + "printf copy-body > \(Self.shellQuote(remoteRoot + "/copy-source.txt")); "
                + "printf move-body > \(Self.shellQuote(remoteRoot + "/move-source.txt"))"
        )
        let copySource = Location.remote(hostID: session.hostID, path: remoteRoot + "/copy-source.txt")
        let moveSource = Location.remote(hostID: session.hostID, path: remoteRoot + "/move-source.txt")
        let copyDestination = Location.remote(hostID: session.hostID, path: remoteRoot + "/copy-destination")
        let moveDestination = Location.remote(hostID: session.hostID, path: remoteRoot + "/move-destination")

        let copied = try await session.provider.copy([copySource], to: copyDestination)
        let moved = try await session.provider.move([moveSource], to: moveDestination)

        XCTAssertEqual(copied, [copyDestination.appendingPathComponent("copy-source.txt")])
        XCTAssertEqual(moved, [moveDestination.appendingPathComponent("move-source.txt")])
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(copied[0].path))"), "copy-body")
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(moved[0].path))"), "move-body")
        XCTAssertTrue(try Self.remotePathExists(copySource.path))
        XCTAssertFalse(try Self.remotePathExists(moveSource.path))
    }

    @MainActor
    func testLocalRemoteAndCrossHostFolderTransfers() async throws {
        let sessionA = try await RemoteIntegrationSession.make()
        let sessionB = try await RemoteIntegrationSession.make()
        let remoteRoot = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(remoteRoot) }
        try Self.runSSH(
            "mkdir -p \(Self.shellQuote(remoteRoot + "/to-remote")) "
                + "\(Self.shellQuote(remoteRoot + "/remote-folder")) "
                + "\(Self.shellQuote(remoteRoot + "/cross-source")) "
                + "\(Self.shellQuote(remoteRoot + "/cross-destination")); "
                + "printf remote-folder-body > \(Self.shellQuote(remoteRoot + "/remote-folder/nested.txt")); "
                + "printf cross-host-body > \(Self.shellQuote(remoteRoot + "/cross-source/child.txt"))"
        )
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let localFolder = try createTestFolder(in: localRoot, name: "local-folder")
        _ = try createTestFile(in: localFolder, name: "nested.txt", content: "local-folder-body")
        let localDestination = try createTestFolder(in: localRoot, name: "from-remote")
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(sessionA.provider, for: sessionA.hostID)
        queue.registerRemoteFileProvider(sessionB.provider, for: sessionB.hostID)
        defer {
            queue.unregisterRemoteFileProvider(for: sessionA.hostID)
            queue.unregisterRemoteFileProvider(for: sessionB.hostID)
        }

        let remoteDestination = Location.remote(hostID: sessionA.hostID, path: remoteRoot + "/to-remote")
        let localToRemote = try await queue.copy(items: [.local(localFolder)], to: remoteDestination)
        let remoteFolder = Location.remote(hostID: sessionA.hostID, path: remoteRoot + "/remote-folder")
        let remoteToLocal = try await queue.copy(items: [remoteFolder], to: .local(localDestination))
        let crossSource = Location.remote(hostID: sessionA.hostID, path: remoteRoot + "/cross-source")
        let crossDestination = Location.remote(hostID: sessionB.hostID, path: remoteRoot + "/cross-destination")
        let crossHost = try await queue.copy(items: [crossSource], to: crossDestination)

        XCTAssertEqual(localToRemote, [remoteDestination.appendingPathComponent("local-folder")])
        XCTAssertEqual(
            try Self.runSSH("cat \(Self.shellQuote(localToRemote[0].path + "/nested.txt"))"),
            "local-folder-body"
        )
        XCTAssertEqual(remoteToLocal, [.local(localDestination.appendingPathComponent("remote-folder"))])
        XCTAssertEqual(
            try String(contentsOf: remoteToLocal[0].url.appendingPathComponent("nested.txt"), encoding: .utf8),
            "remote-folder-body"
        )
        XCTAssertEqual(crossHost, [crossDestination.appendingPathComponent("cross-source")])
        XCTAssertEqual(
            try Self.runSSH("cat \(Self.shellQuote(crossHost[0].path + "/child.txt"))"),
            "cross-host-body"
        )
        XCTAssertTrue(try Self.remotePathExists(crossSource.path + "/child.txt"))
    }

    private static func makeRemoteFixtureRoot() throws -> String {
        try makeRemoteFixtureRoot(target: linuxTestTarget)
    }

    private static func makeRemoteFixtureRoot(target: String) throws -> String {
        let root = try runSSH("printf %s \"$HOME/.detours-test/\(UUID().uuidString)\"", target: target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runSSH("mkdir -p \(shellQuote(root))", target: target)
        return root
    }

    private static func cleanupRemote(_ path: String) {
        cleanupRemote(path, target: linuxTestTarget)
    }

    private static func cleanupRemote(_ path: String, target: String) {
        _ = try? runSSH("rm -rf \(shellQuote(path))", target: target)
    }

    private static func waitForRemotePath(_ path: String, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try remotePathExists(path) {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Remote path was not restored within \(timeout) seconds: \(path)")
    }

    private static func remotePathExists(_ path: String) throws -> Bool {
        try remotePathExists(path, target: linuxTestTarget)
    }

    private static func remotePathExists(_ path: String, target: String) throws -> Bool {
        let process = try configuredSSHProcess(command: "test -e \(shellQuote(path))", target: target)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard process.waitUntilExit(timeout: 5) else {
            process.terminate()
            throw XCTSkip("\(target) timed out")
        }
        return process.terminationStatus == 0
    }

    @discardableResult
    static func runSSH(_ command: String) throws -> String {
        try runSSH(command, target: linuxTestTarget)
    }

    @discardableResult
    static func runSSH(_ command: String, target: String) throws -> String {
        let process = try configuredSSHProcess(command: command, target: target)
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        guard process.waitUntilExit(timeout: 15) else {
            process.terminate()
            throw XCTSkip("\(target) timed out")
        }
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(target) unavailable: \(stderr)")
        }
        return stdout
    }

    fileprivate static func configuredSSHProcess(command: String, target: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            target,
            command,
        ]
        return process
    }

    static func prepareDefaultSSHControlDirectory() throws {
        let controlDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory.path)
    }

    static func requireIntelMacHost(_ target: String) throws {
        let architecture = try runSSH("uname -sm", target: target).trimmingCharacters(in: .whitespacesAndNewlines)
        guard architecture == "Darwin x86_64" else {
            throw XCTSkip("\(target) reported \(architecture), expected Darwin x86_64")
        }
    }

    fileprivate static func remoteHome(target: String) throws -> String {
        try runSSH("printf %s \"$HOME\"", target: target).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func makeDefaults() throws -> UserDefaults {
        let suiteName = "RemoteIntegrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

struct ProcessRemoteRPCClient: RemoteRPCClient {
    let sshTarget: String

    init() {
        self.init(sshTarget: RemoteIntegrationTests.linuxTestTarget)
    }

    init(sshTarget: String) {
        self.sshTarget = sshTarget
    }

    func send(_ message: RPCMessage) async throws -> [Data] {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(FileManager.default.homeDirectoryForCurrentUser.path)/.detours/ssh/%C",
            "-o", "UserKnownHostsFile=\(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh/known_hosts",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PubkeyAuthentication=yes",
            "-o", "NumberOfPasswordPrompts=0",
            sshTarget,
            "~/.detours-server/detours-server",
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let request = RPCEnvelope(
            id: 1,
            kind: .request,
            messageType: message.messageType,
            sequence: 0,
            isFinal: true,
            payload: try message.binaryEncoded()
        )
        let frame = try RPCStreamHandler.encodeFrame(request.encodedPayload())
        stdin.fileHandleForWriting.write(frame)
        try stdin.fileHandleForWriting.close()

        guard process.waitUntilExit(timeout: 15) else {
            process.terminate()
            throw RemoteFileProviderError.invalidResponse("\(sshTarget) RPC timed out")
        }
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RemoteFileProviderError.invalidResponse("\(sshTarget) RPC failed: \(stderrText)")
        }

        var stream = RPCStreamHandler()
        let frames = try stream.append(stdout.fileHandleForReading.readDataToEndOfFile())
        let decoded = try frames.map { frame in
            try RPCEnvelope(encodedPayload: frame)
        }
        if let error = decoded.first(where: { envelope in
            envelope.id == 1 && envelope.kind == .error
        }) {
            var reader = RPCBinaryReader(data: error.payload)
            let message = (try? reader.readString()) ?? "The remote server reported an error."
            throw RemoteFileProviderError.invalidResponse(message)
        }
        let responses = decoded.filter { envelope in
            envelope.id == 1 && envelope.kind == .response
        }
        let envelopes = responses.sorted { lhs, rhs in
            lhs.sequence < rhs.sequence
        }
        guard envelopes.last?.isFinal == true else {
            throw RemoteFileProviderError.invalidResponse("devtest RPC missing final frame")
        }
        return envelopes.map { $0.payload }
    }
}

private extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        terminationHandler = { _ in semaphore.signal() }
        if !isRunning { return true }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
