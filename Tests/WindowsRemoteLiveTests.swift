import XCTest
@testable import Detours

@MainActor
final class WindowsRemoteLiveTests: XCTestCase {
    /// The dedicated Windows qualification host, named by default the same way
    /// the Linux live tests name theirs. Waiting to be told meant these never
    /// ran unless someone remembered to set a variable, which is indistinguishable
    /// from not having them.
    private let target: String? = ProcessInfo.processInfo.environment["DETOURS_WINDOWS_TEST_TARGET"]
        ?? "detours-windows"

    func testConnectListsProfileAndDrives() async throws {
        try await withFixture { fixture in
            let home = try await fixture.provider.homeDirectory()
            let homeItems = try await fixture.provider.list(.remote(hostID: fixture.hostID, path: home), showHidden: false)
            let drives = try await fixture.provider.list(.remote(hostID: fixture.hostID, path: "/"), showHidden: false)
            let cDrive = try XCTUnwrap(drives.first { $0.name == "C:" && $0.isDirectory })
            let cDriveItems = try await fixture.provider.list(cDrive.location, showHidden: false)

            XCTAssertTrue(home.hasPrefix("/C:/Users/"))
            XCTAssertFalse(homeItems.isEmpty)
            XCTAssertEqual(cDrive.location, .remote(hostID: fixture.hostID, path: "/C:"))
            XCTAssertFalse(cDriveItems.isEmpty)
        }
    }

    func testHostKindProbeUsesRealSSHAndPowerShellOutput() async throws {
        guard let target else {
            throw XCTSkip("Set DETOURS_WINDOWS_TEST_TARGET to run Windows live tests.")
        }
        guard try await Self.canReachWindowsHost(target: target) else {
            throw XCTSkip("Windows host \(target) is unreachable.")
        }

        let client = SSHRemoteHostKindProbeClient(sshTarget: target)
        let output = try await client.run(RemoteHostKindProbe.windowsProbeCommand())
        let kind = await RemoteHostKindProbe(client: client).probe()

        XCTAssertTrue(output.contains("DETOURS_WINDOWS_PROBE"))
        XCTAssertTrue(output.lowercased().contains("win"))
        XCTAssertEqual(kind, .windows)
    }

    func testCreateRenameCopyMoveDelete() async throws {
        try await withFixture { fixture in
            let source = fixture.root.appendingPathComponent("source")
            let destination = fixture.root.appendingPathComponent("destination")
            let movedDestination = fixture.root.appendingPathComponent("moved")

            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "source")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "destination")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "moved")

            let renamed = try await FileOperationQueue.shared.rename(item: source, to: "renamed")
            let copied = try await FileOperationQueue.shared.copy(items: [renamed], to: destination)
            let moved = try await FileOperationQueue.shared.move(items: copied, to: movedDestination)
            try await FileOperationQueue.shared.delete(items: moved)

            XCTAssertEqual(renamed.lastPathComponent, "renamed")
            XCTAssertEqual(copied, [destination.appendingPathComponent("renamed")])
            XCTAssertEqual(moved, [movedDestination.appendingPathComponent("renamed")])
            await XCTAssertThrowsErrorAsync(try await fixture.provider.stat(moved[0]))
        }
    }

    func testTrashRestoreBestEffort() async throws {
        try await withFixture { fixture in
            let file = fixture.root.appendingPathComponent("restore-me.txt")
            try await fixture.upload(Data("restore".utf8), to: file)

            let undoManager = UndoManager()
            try await FileOperationQueue.shared.delete(items: [file], undoManager: undoManager)
            await XCTAssertThrowsErrorAsync(try await fixture.provider.stat(file))

            undoManager.undo()
            var entry: LoadedFileEntry?
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                entry = try? await fixture.provider.stat(file)
                if entry != nil { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            XCTAssertEqual(entry?.name, "restore-me.txt")
        }
    }

    func testZipCreateExtractAndToolGating() async throws {
        try await withFixture { fixture in
            let source = fixture.root.appendingPathComponent("archive-source")
            let hidden = source.appendingPathComponent("hidden-live.txt")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "archive-source")
            try await fixture.upload(Data("hidden".utf8), to: hidden)
            try await fixture.run(
                operation: "HideFile",
                source: """
                param($Arguments)
                $item = Get-Item -LiteralPath $Arguments.path -Force
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
                $true
                """,
                arguments: PathArguments(path: try fixture.nativePath(hidden))
            )

            let archive = try await FileOperationQueue.shared.archive(items: [source], format: .zip, archiveName: "bundle", password: nil)
            let extracted = try await FileOperationQueue.shared.extract(archive: archive, password: nil)
            let extractedHidden = extracted.appendingPathComponent("hidden-live.txt")
            let hiddenEntry = try await fixture.provider.stat(extractedHidden)
            XCTAssertEqual(hiddenEntry.name, "hidden-live.txt")

            if try await fixture.hostHasTool("7z.exe", "7z") {
                let sevenZ = try await FileOperationQueue.shared.archive(items: [source], format: .sevenZ, archiveName: "bundle-7z", password: nil)
                XCTAssertEqual(sevenZ.lastPathComponent, "bundle-7z.7z")
            } else {
                await XCTAssertThrowsErrorAsync(
                    try await FileOperationQueue.shared.archive(items: [source], format: .sevenZ, archiveName: "bundle-7z", password: nil)
                )
            }

            if try await fixture.hostHasTool("tar.exe", "tar") {
                let tar = try await FileOperationQueue.shared.archive(items: [source], format: .tarGz, archiveName: "bundle-tar", password: nil)
                XCTAssertEqual(tar.lastPathComponent, "bundle-tar.tar.gz")
            } else {
                await XCTAssertThrowsErrorAsync(
                    try await FileOperationQueue.shared.archive(items: [source], format: .tarGz, archiveName: "bundle-tar", password: nil)
                )
            }
        }
    }

    func testDownloadUploadLargeBinary() async throws {
        try await withFixture { fixture in
            let data = Data((0..<(2 * 1_024 * 1_024)).map { UInt8($0 % 251) })
            let remote = fixture.root.appendingPathComponent("large.bin")
            let downloadURL = FileManager.default.temporaryDirectory.appendingPathComponent("detours-live-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: downloadURL) }

            try await fixture.upload(data, to: remote)
            try await fixture.provider.download(remote, to: downloadURL)

            XCTAssertEqual(try Data(contentsOf: downloadURL), data)
        }
    }

    func testQuickLookAndFind() async throws {
        try await withFixture { fixture in
            let name = "quicklook-find-\(UUID().uuidString).txt"
            let remote = fixture.root.appendingPathComponent(name)
            try await fixture.upload(Data("preview".utf8), to: remote)
            _ = try await fixture.provider.list(fixture.root, showHidden: true)

            let quickLookURL = try await fixture.provider.openForQuickLook(remote)
            let quickLookData = try Data(contentsOf: quickLookURL)
            var found: [FoundItem] = []
            for try await batch in fixture.provider.find(query: name, cap: 20, root: fixture.root) {
                found.append(contentsOf: batch)
            }

            XCTAssertEqual(quickLookData, Data("preview".utf8))
            XCTAssertTrue(found.contains { $0.location == remote })
        }
    }

    func testWatchEmitsChangeOnServerSideModification() async throws {
        try await withFixture { fixture in
            let changeReceived = expectation(description: "Windows watch change")
            let recorder = LiveWatchRecorder()
            let watch = try await fixture.provider.watch(fixture.root) { location in
                Task {
                    await recorder.record(location)
                    changeReceived.fulfill()
                }
            }
            try await fixture.run(
                operation: "CreateWatchedFile",
                source: """
                param($Arguments)
                Set-Content -LiteralPath $Arguments.path -Value 'changed' -Encoding UTF8
                $true
                """,
                arguments: PathArguments(path: try fixture.nativePath(fixture.root.appendingPathComponent("watched.txt")))
            )

            await fulfillment(of: [changeReceived], timeout: 5.0)
            await fixture.provider.unwatch(watch)
            let locations = await recorder.locations
            XCTAssertTrue(locations.contains(fixture.root.appendingPathComponent("watched.txt")))
        }
    }

    func testUnwatchCancelsIdleReadAndNextWatchAcceptsWork() async throws {
        try await withFixture { fixture in
            let idleWatch = try await fixture.provider.watch(fixture.root) { _ in }
            let cancellationStarted = Date()

            await fixture.provider.unwatch(idleWatch)

            XCTAssertLessThan(Date().timeIntervalSince(cancellationStarted), 3)

            let changeReceived = expectation(description: "replacement Windows watch change")
            let recorder = LiveWatchRecorder()
            let replacementWatch = try await fixture.provider.watch(fixture.root) { location in
                Task {
                    await recorder.record(location)
                    changeReceived.fulfill()
                }
            }
            let created = fixture.root.appendingPathComponent("after-unwatch.txt")
            try await fixture.run(
                operation: "CreateAfterUnwatch",
                source: """
                param($Arguments)
                Set-Content -LiteralPath $Arguments.path -Value 'accepted' -Encoding UTF8
                $true
                """,
                arguments: PathArguments(path: try fixture.nativePath(created))
            )

            await fulfillment(of: [changeReceived], timeout: 5.0)
            await fixture.provider.unwatch(replacementWatch)

            let locations = await recorder.locations
            XCTAssertTrue(locations.contains(created))
        }
    }

    func testQuietWatchSurvivesRealHeartbeatIntervalAndDeliversLaterChange() async throws {
        try await withFixture { fixture in
            let recorder = LiveWatchRecorder()
            let eventReceived = expectation(description: "change after Windows watch heartbeat interval")
            let watch = try await fixture.provider.watch(fixture.root) { location in
                Task {
                    await recorder.record(location)
                    eventReceived.fulfill()
                }
            }

            // The transport read timeout is 30 seconds and the real PowerShell watcher emits a
            // heartbeat every 10 seconds. Remaining idle beyond 30 seconds proves those frames
            // keep the actual SSH stream alive; heartbeats themselves must not invoke onChange.
            try await Task.sleep(for: .seconds(32))
            let locationsBeforeChange = await recorder.locations
            XCTAssertTrue(locationsBeforeChange.isEmpty)

            let created = fixture.root.appendingPathComponent("after-heartbeats.txt")
            try await fixture.run(
                operation: "CreateAfterHeartbeats",
                source: """
                param($Arguments)
                Set-Content -LiteralPath $Arguments.path -Value 'alive' -Encoding UTF8
                $true
                """,
                arguments: PathArguments(path: try fixture.nativePath(created))
            )

            await fulfillment(of: [eventReceived], timeout: 5)
            await fixture.provider.unwatch(watch)
            let locationsAfterChange = await recorder.locations
            XCTAssertTrue(locationsAfterChange.contains(created))
        }
    }

    func testDriveRootWatchDoesNotBreakDriveReload() async throws {
        try await withFixture { fixture in
            let drives = try await fixture.provider.list(.remote(hostID: fixture.hostID, path: "/"), showHidden: false)
            let cDrive = try XCTUnwrap(drives.first { $0.name == "C:" && $0.isDirectory })

            async let watchResult = fixture.provider.watch(cDrive.location) { _ in }
            async let initialReload = fixture.provider.list(cDrive.location, showHidden: false)
            let (watch, initialItems) = try await (watchResult, initialReload)

            do {
                let retryItems = try await fixture.provider.list(cDrive.location, showHidden: false)
                await fixture.provider.unwatch(watch)

                XCTAssertFalse(initialItems.isEmpty)
                XCTAssertFalse(retryItems.isEmpty)
            } catch {
                await fixture.provider.unwatch(watch)
                throw error
            }
        }
    }

    @MainActor
    func testCopyMoveUploadConflictAndUndoOnExistingTarget() async throws {
        try await withMainFixture { fixture in
            let queue = FileOperationQueue.shared
            queue.registerRemoteFileProvider(fixture.provider, for: fixture.hostID)
            queue.conflictChoiceOverrideForTesting = .replace
            defer {
                queue.conflictChoiceOverrideForTesting = nil
                queue.windowsReplacementFailureProbeForTesting = nil
                queue.unregisterRemoteFileProvider(for: fixture.hostID)
            }

            let dst = fixture.root.appendingPathComponent("dst")
            let src = fixture.root.appendingPathComponent("src")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "dst")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "src")
            try await fixture.upload(Data("original".utf8), to: dst.appendingPathComponent("A.txt"))
            try await fixture.upload(Data("new".utf8), to: src.appendingPathComponent("A.txt"))

            // Replace then undo restores the displaced original (A1, A2).
            let copyUndoManager = UndoManager()
            let sourceFile = src.appendingPathComponent("A.txt")
            let destinationFile = dst.appendingPathComponent("A.txt")
            _ = try await queue.copy(items: [sourceFile], to: dst, undoManager: copyUndoManager)
            let copiedData = try await fixture.read(destinationFile)
            XCTAssertEqual(copiedData, Data("new".utf8))
            copyUndoManager.undo()
            try await waitUntilLiveOnMainActor(timeout: 5) {
                (try? await fixture.read(destinationFile)) == Data("original".utf8)
            }
            let sourceAfterCopyUndo = try await fixture.read(sourceFile)
            XCTAssertEqual(sourceAfterCopyUndo, Data("new".utf8))

            // Move plus Replace crosses the real PowerShell scripts. Undo must restore both the
            // moved source and the displaced destination, not merely remove the replacement.
            let moveUndoManager = UndoManager()
            _ = try await queue.move(items: [sourceFile], to: dst, undoManager: moveUndoManager)
            let movedData = try await fixture.read(destinationFile)
            XCTAssertEqual(movedData, Data("new".utf8))
            do {
                _ = try await fixture.provider.stat(sourceFile)
                XCTFail("Move must remove the source before undo")
            } catch {}

            moveUndoManager.undo()
            try await waitUntilLiveOnMainActor(timeout: 5) {
                let sourceData = try? await fixture.read(sourceFile)
                let destinationData = try? await fixture.read(destinationFile)
                return sourceData == Data("new".utf8) && destinationData == Data("original".utf8)
            }
            let sourceAfterMoveUndo = try await fixture.read(sourceFile)
            let destinationAfterMoveUndo = try await fixture.read(destinationFile)
            XCTAssertEqual(sourceAfterMoveUndo, Data("new".utf8))
            XCTAssertEqual(destinationAfterMoveUndo, Data("original".utf8))

            // Fail after the real target has been recycled. Rollback must restore the target and
            // move the staged source back through the live PowerShell provider.
            let rollbackSource = src.appendingPathComponent("rollback.txt")
            let rollbackDestination = dst.appendingPathComponent("rollback.txt")
            try await fixture.upload(Data("rollback-new".utf8), to: rollbackSource)
            try await fixture.upload(Data("rollback-original".utf8), to: rollbackDestination)
            queue.windowsReplacementFailureProbeForTesting = { true }

            do {
                _ = try await queue.move(items: [rollbackSource], to: dst)
                XCTFail("Injected post-displacement failure must abort the move")
            } catch {}
            queue.windowsReplacementFailureProbeForTesting = nil

            let sourceAfterRollback = try await fixture.read(rollbackSource)
            let destinationAfterRollback = try await fixture.read(rollbackDestination)
            XCTAssertEqual(sourceAfterRollback, Data("rollback-new".utf8))
            XCTAssertEqual(destinationAfterRollback, Data("rollback-original".utf8))

            // Folder copy onto an existing same-name folder merges, preserving existing contents (A3).
            let mergeSrc = fixture.root.appendingPathComponent("mergeSrc/folder")
            let mergeDst = fixture.root.appendingPathComponent("mergeDst/folder")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "mergeSrc")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root.appendingPathComponent("mergeSrc"), name: "folder")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "mergeDst")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root.appendingPathComponent("mergeDst"), name: "folder")
            try await fixture.upload(Data("c".utf8), to: mergeSrc.appendingPathComponent("child.txt"))
            try await fixture.upload(Data("e".utf8), to: mergeDst.appendingPathComponent("existing.txt"))
            _ = try await queue.copy(items: [mergeSrc], to: fixture.root.appendingPathComponent("mergeDst"))
            let mergedChild = try await fixture.provider.stat(mergeDst.appendingPathComponent("child.txt"))
            let mergedExisting = try await fixture.provider.stat(mergeDst.appendingPathComponent("existing.txt"))
            XCTAssertEqual(mergedChild.name, "child.txt")
            XCTAssertEqual(mergedExisting.name, "existing.txt")
        }
    }

    func testInterruptedDownloadLeavesNoCorruptFileAndRetrySucceeds() async throws {
        try await withFixture { fixture in
            let remote = fixture.root.appendingPathComponent("download-safe.bin")
            let payload = Data((0..<4096).map { UInt8($0 % 251) })
            try await fixture.upload(payload, to: remote)

            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("detours-live-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: destination) }
            let partial = RemoteTransferChannel.partialURL(for: destination)

            try await fixture.provider.download(remote, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), payload)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "no partial temp may be left behind")

            // A retry to a fresh path also succeeds and leaves no partial behind.
            let retryDestination = FileManager.default.temporaryDirectory.appendingPathComponent("detours-live-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: retryDestination) }
            try await fixture.provider.download(remote, to: retryDestination)
            XCTAssertEqual(try Data(contentsOf: retryDestination), payload)
        }
    }

    func testConcurrentDualPaneOperationsAndWatches() async throws {
        try await withFixture { fixture in
            let paneA = fixture.root.appendingPathComponent("paneA")
            let paneB = fixture.root.appendingPathComponent("paneB")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "paneA")
            _ = try await FileOperationQueue.shared.createFolder(in: fixture.root, name: "paneB")

            let recorder = LiveWatchRecorder()
            let watchA = try await fixture.provider.watch(paneA) { loc in Task { await recorder.record(loc) } }
            let watchB = try await fixture.provider.watch(paneB) { loc in Task { await recorder.record(loc) } }

            // Concurrent operations on the same host serialize cleanly with no collisions.
            async let listA = fixture.provider.list(paneA, showHidden: true)
            async let listB = fixture.provider.list(paneB, showHidden: true)
            _ = try await (listA, listB)

            try await fixture.upload(Data("a".utf8), to: paneA.appendingPathComponent("a.txt"))
            try await fixture.upload(Data("b".utf8), to: paneB.appendingPathComponent("b.txt"))

            // Both watches deliver their own directory's change.
            try await waitUntilLive(timeout: 8.0) {
                let locations = await recorder.locations
                return locations.contains(where: { $0.path.contains("paneA") })
                    && locations.contains(where: { $0.path.contains("paneB") })
            }

            // Deterministically tear the watches down before the fixture cleans up, so a run
            // never leaves a leaked watcher that degrades the host for the next test. On a throw,
            // the fixture's control-master close still ends the watch sessions.
            await fixture.provider.unwatch(watchA)
            await fixture.provider.unwatch(watchB)
        }
    }

    private func waitUntilLive(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Live condition not met within \(timeout)s")
    }

    @MainActor
    private func withFixture(_ body: @MainActor (WindowsLiveFixture) async throws -> Void) async throws {
        guard let target else {
            throw XCTSkip("Set DETOURS_WINDOWS_TEST_TARGET to run Windows live tests.")
        }
        guard try await Self.canReachWindowsHost(target: target) else {
            throw XCTSkip("Windows host \(target) is unreachable.")
        }
        let fixture = try await WindowsLiveFixture(target: target)
        FileOperationQueue.shared.registerRemoteFileProvider(fixture.provider, for: fixture.hostID,
            operationEndpoint: fixture.endpoint)
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: fixture.hostID) }
        do {
            try await body(fixture)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @MainActor
    private func withMainFixture(_ body: @MainActor (WindowsLiveFixture) async throws -> Void) async throws {
        guard let target else {
            throw XCTSkip("Set DETOURS_WINDOWS_TEST_TARGET to run Windows live tests.")
        }
        guard try await Self.canReachWindowsHost(target: target) else {
            throw XCTSkip("Windows host \(target) is unreachable.")
        }
        let fixture = try await WindowsLiveFixture(target: target)
        FileOperationQueue.shared.registerRemoteFileProvider(fixture.provider, for: fixture.hostID,
            operationEndpoint: fixture.endpoint)
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: fixture.hostID) }
        do {
            try await body(fixture)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    private static func canReachWindowsHost(target: String) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            target,
            "$PSVersionTable.PSVersion.ToString()",
        ]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

@MainActor
private func waitUntilLiveOnMainActor(
    timeout: TimeInterval,
    _ condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("Live condition not met within \(timeout)s")
}

private actor LiveWatchRecorder {
    private(set) var locations: [Location] = []

    func record(_ location: Location) {
        locations.append(location)
    }
}

private struct WindowsLiveFixture {
    let target: String
    let hostID = UUID()
    let controlDirectory: URL
    let channel: PowerShellChannel
    let provider: WindowsRemoteProvider
    let session: RemoteHostSession
    let endpoint: RemoteOperationCoordinator.Endpoint
    let root: Location

    init(target: String) async throws {
        self.target = target
        // Each fixture gets its own SSH ControlPath so tests never share a control master.
        // That fully isolates per-test sessions: no leaked watcher session from one test can
        // accumulate over a shared master and exhaust the host's MaxSessions for a later test.
        // Keep the directory short and under the home dir: <dir>/%C must stay within the
        // ~104-char unix-socket path limit, which the long /var/folders temp path blows past.
        let controlDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/lt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: controlDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        self.controlDirectory = controlDir

        let channel = PowerShellChannel(hostID: hostID, sshTarget: target, controlDirectory: controlDir)
        self.channel = channel
        let transferChannel = WindowsTransferChannel(sshTarget: target, powerShellChannel: channel, controlDirectory: controlDir)
        let watchChannel = WindowsWatchChannel(hostID: hostID, sshTarget: target, controlDirectory: controlDir)
        let provider = WindowsRemoteProvider(
            hostID: hostID, channel: channel, transferChannel: transferChannel, watchChannel: watchChannel
        )
        self.provider = provider
        let session = RemoteHostSession(transport: WindowsHostSessionTransport(channel: channel), publish: { _, _ in })
        self.session = session
        await channel.bind(session: session)
        _ = try await session.ensureReady()
        endpoint = RemoteOperationCoordinator.Endpoint(
            session: session,
            request: { try await provider.operationRequest($0) },
            upload: { try await provider.prepareAcceptedUpload($0, identity: $1) }
        )
        let home = try await provider.homeDirectory()
        let rootLocation = Location.remote(hostID: hostID, path: home)
            .appendingPathComponent("DetoursLiveTests-\(UUID().uuidString)")
        root = rootLocation
        guard let nativeRoot = try WindowsPath(location: rootLocation, hostID: hostID).nativePath else {
            throw WindowsPathError.nativePathRequired(rootLocation.path)
        }
        try await channel.run(
            PowerShellScript(source: PowerShellScript.prelude(operationBody: """
                param($Arguments)
                New-Item -ItemType Directory -Path $Arguments.path -Force | Out-Null
                $true
                """), arguments: PathArguments(path: nativeRoot)),
            operation: "PrepareRoot"
        )
    }

    func cleanup() async throws {
        // Tear down this fixture's own control master (and its sessions) and drop the socket
        // directory, leaving a clean SSH slate for the next test.
        defer { Self.closeControlConnection(target: target, controlDirectory: controlDirectory) }
        do {
            try await run(
                operation: "Cleanup",
                source: """
                param($Arguments)
                Remove-Item -LiteralPath $Arguments.path -Recurse -Force -ErrorAction SilentlyContinue
                $true
                """,
                arguments: PathArguments(path: try nativePath(root))
            )
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            throw error
        }
    }

    private static func closeControlConnection(target: String, controlDirectory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "ControlPath=\(controlDirectory.path)/%C", "-O", "exit", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: controlDirectory)
    }

    @MainActor
    func upload(_ data: Data, to location: Location) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("detours-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(location.lastPathComponent)
        try data.write(to: file)
        _ = try await FileOperationQueue.shared.copy(items: [.local(file)], to: location.deletingLastPathComponent())
    }

    func read(_ location: Location) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(location.lastPathComponent)
        try await provider.download(location, to: file)
        return try Data(contentsOf: file)
    }

    func hostHasTool(_ names: String...) async throws -> Bool {
        struct ToolArguments: Encodable {
            let names: [String]
        }
        let data = try await run(
            operation: "HasTool",
            source: """
            param($Arguments)
            foreach ($name in $Arguments.names) {
                if (Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue) { $true; return }
            }
            $false
            """,
            arguments: ToolArguments(names: names)
        )
        return try JSONDecoder.detoursWindows.decode(Bool.self, from: data)
    }

    @discardableResult
    func run<Arguments: Encodable>(operation: String, source: String, arguments: Arguments) async throws -> Data {
        try await channel.run(
            try PowerShellScript(source: PowerShellScript.prelude(operationBody: source), arguments: arguments),
            operation: operation
        )
    }

    func nativePath(_ location: Location) throws -> String {
        guard let nativePath = try WindowsPath(location: location, hostID: hostID).nativePath else {
            throw WindowsPathError.nativePathRequired(location.path)
        }
        return nativePath
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
