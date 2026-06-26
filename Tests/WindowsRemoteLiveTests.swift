import XCTest
@testable import Detours

final class WindowsRemoteLiveTests: XCTestCase {
    private let target = ProcessInfo.processInfo.environment["DETOURS_WINDOWS_TEST_TARGET"]

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

    func testCreateRenameCopyMoveDelete() async throws {
        try await withFixture { fixture in
            let source = fixture.root.appendingPathComponent("source")
            let destination = fixture.root.appendingPathComponent("destination")
            let movedDestination = fixture.root.appendingPathComponent("moved")

            try await fixture.provider.createDirectory(at: source, withIntermediateDirectories: false)
            try await fixture.provider.createDirectory(at: destination, withIntermediateDirectories: false)
            try await fixture.provider.createDirectory(at: movedDestination, withIntermediateDirectories: false)

            let renamed = try await fixture.provider.rename(source, to: "renamed")
            let copied = try await fixture.provider.copy([renamed], to: destination)
            let moved = try await fixture.provider.move(copied, to: movedDestination)
            try await fixture.provider.delete(moved)

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

            let trashed = try await fixture.provider.trash([file])
            await XCTAssertThrowsErrorAsync(try await fixture.provider.stat(file))
            let restored = try await fixture.provider.restoreFromTrash(trashed)
            let entry = try await fixture.provider.stat(file)

            XCTAssertEqual(restored, [file])
            XCTAssertEqual(entry.name, "restore-me.txt")
        }
    }

    func testZipCreateExtractAndToolGating() async throws {
        try await withFixture { fixture in
            let source = fixture.root.appendingPathComponent("archive-source")
            let hidden = source.appendingPathComponent("hidden-live.txt")
            try await fixture.provider.createDirectory(at: source, withIntermediateDirectories: false)
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

            let archive = try await fixture.provider.archiveCreate([source], format: .zip, archiveName: "bundle", password: nil)
            let extracted = try await fixture.provider.archiveExtract(archive, password: nil)
            let extractedHidden = extracted.appendingPathComponent("hidden-live.txt")
            let hiddenEntry = try await fixture.provider.stat(extractedHidden)
            XCTAssertEqual(hiddenEntry.name, "hidden-live.txt")

            if try await fixture.hostHasTool("7z.exe", "7z") {
                let sevenZ = try await fixture.provider.archiveCreate([source], format: .sevenZ, archiveName: "bundle-7z", password: nil)
                XCTAssertEqual(sevenZ.lastPathComponent, "bundle-7z.7z")
            } else {
                await XCTAssertThrowsErrorAsync(
                    try await fixture.provider.archiveCreate([source], format: .sevenZ, archiveName: "bundle-7z", password: nil)
                )
            }

            if try await fixture.hostHasTool("tar.exe", "tar") {
                let tar = try await fixture.provider.archiveCreate([source], format: .tarGz, archiveName: "bundle-tar", password: nil)
                XCTAssertEqual(tar.lastPathComponent, "bundle-tar.tar.gz")
            } else {
                await XCTAssertThrowsErrorAsync(
                    try await fixture.provider.archiveCreate([source], format: .tarGz, archiveName: "bundle-tar", password: nil)
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
            defer {
                Task { await fixture.provider.unwatch(watch) }
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
            let locations = await recorder.locations
            XCTAssertTrue(locations.contains(fixture.root.appendingPathComponent("watched.txt")))
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
            defer { queue.unregisterRemoteFileProvider(for: fixture.hostID) }

            let dst = fixture.root.appendingPathComponent("dst")
            let src = fixture.root.appendingPathComponent("src")
            try await fixture.provider.createDirectory(at: dst, withIntermediateDirectories: false)
            try await fixture.provider.createDirectory(at: src, withIntermediateDirectories: false)
            try await fixture.upload(Data("original".utf8), to: dst.appendingPathComponent("A.txt"))
            try await fixture.upload(Data("new".utf8), to: src.appendingPathComponent("A.txt"))

            // Replace then undo restores the displaced original (A1, A2).
            let undoManager = UndoManager()
            queue.conflictChoiceOverrideForTesting = .replace
            _ = try await queue.copy(items: [src.appendingPathComponent("A.txt")], to: dst, undoManager: undoManager)
            queue.conflictChoiceOverrideForTesting = nil
            undoManager.undo()
            try await Task.sleep(nanoseconds: 800_000_000)
            let restored = try await fixture.provider.stat(dst.appendingPathComponent("A.txt"))
            XCTAssertEqual(restored.name, "A.txt")

            // Folder copy onto an existing same-name folder merges, preserving existing contents (A3).
            let mergeSrc = fixture.root.appendingPathComponent("mergeSrc/folder")
            let mergeDst = fixture.root.appendingPathComponent("mergeDst/folder")
            try await fixture.provider.createDirectory(at: mergeSrc, withIntermediateDirectories: true)
            try await fixture.provider.createDirectory(at: mergeDst, withIntermediateDirectories: true)
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
            try await fixture.provider.createDirectory(at: paneA, withIntermediateDirectories: false)
            try await fixture.provider.createDirectory(at: paneB, withIntermediateDirectories: false)

            let recorder = LiveWatchRecorder()
            let watchA = try await fixture.provider.watch(paneA) { loc in Task { await recorder.record(loc) } }
            let watchB = try await fixture.provider.watch(paneB) { loc in Task { await recorder.record(loc) } }
            defer { Task { await fixture.provider.unwatch(watchA); await fixture.provider.unwatch(watchB) } }

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

    private func withFixture(_ body: (WindowsLiveFixture) async throws -> Void) async throws {
        guard let target else {
            throw XCTSkip("Set DETOURS_WINDOWS_TEST_TARGET to run Windows live tests.")
        }
        guard try await Self.canReachWindowsHost(target: target) else {
            throw XCTSkip("Windows host \(target) is unreachable.")
        }
        let fixture = try await WindowsLiveFixture(target: target)
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
        try await channel.forceReconnect()
        let transferChannel = WindowsTransferChannel(sshTarget: target, powerShellChannel: channel, controlDirectory: controlDir)
        let watchChannel = WindowsWatchChannel(hostID: hostID, sshTarget: target, controlDirectory: controlDir)
        provider = WindowsRemoteProvider(
            hostID: hostID, channel: channel, transferChannel: transferChannel, watchChannel: watchChannel
        )
        let home = try await provider.homeDirectory()
        root = Location.remote(hostID: hostID, path: home)
            .appendingPathComponent("DetoursLiveTests-\(UUID().uuidString)")
        try await provider.createDirectory(at: root, withIntermediateDirectories: false)
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

    func upload(_ data: Data, to location: Location) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("detours-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(location.lastPathComponent)
        try data.write(to: file)
        try await provider.upload(file, to: location)
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
