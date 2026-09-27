import DetoursProcess
import XCTest
@testable import Detours

/// Symbolic links in copy, move and trash against the live Linux test host, through the real
/// helper. Same-host operations keep links; cross-host transfers carry what they point at.
extension RemoteIntegrationTests {
    @MainActor
    private func makeQueueSession() async throws -> RemoteIntegrationSession {
        let session = try await RemoteIntegrationSession.make()
        FileOperationQueue.shared.registerRemoteFileProvider(session.provider, for: session.hostID,
            operationEndpoint: session.endpoint)
        return session
    }

    private static func remoteLinkText(_ path: String) throws -> String {
        try runSSH("readlink \(shellQuote(path))").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func remoteIsLink(_ path: String) throws -> Bool {
        try runSSH("test -L \(shellQuote(path)) && printf yes || printf no") == "yes"
    }

    private static func remoteIsRegularFile(_ path: String) throws -> Bool {
        try runSSH("test -f \(shellQuote(path)) && ! test -L \(shellQuote(path)) && printf yes || printf no") == "yes"
    }

    private static func remoteIsRealDirectory(_ path: String) throws -> Bool {
        try runSSH("test -d \(shellQuote(path)) && ! test -L \(shellQuote(path)) && printf yes || printf no") == "yes"
    }

    /// The Mac spells temporary folders as /var and /private/var; compare with the parent
    /// resolved and the link itself left as it is.
    private static func parentResolvedPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    private static func localIsLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    @MainActor
    func testSameHostCopyOfLinksKeepsLinks() async throws {
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH(
            "cd \(Self.shellQuote(root)) && printf keep > target.txt && ln -s target.txt valid "
                + "&& ln -s missing.txt dangling && ln -s looping looping && mkdir folder dest "
                + "&& ln -s ../target.txt folder/up && ln -s self folder/self"
        )
        let remote = { (name: String) in Location.remote(hostID: session.hostID, path: root + "/" + name) }

        let copied = try await FileOperationQueue.shared.copy(
            items: [remote("valid"), remote("dangling"), remote("looping"), remote("folder")],
            to: remote("dest")
        )

        XCTAssertEqual(copied.map(\.lastPathComponent), ["valid", "dangling", "looping", "folder"])
        XCTAssertEqual(try Self.remoteLinkText(root + "/dest/valid"), "target.txt")
        XCTAssertEqual(try Self.remoteLinkText(root + "/dest/dangling"), "missing.txt")
        XCTAssertEqual(try Self.remoteLinkText(root + "/dest/looping"), "looping")
        XCTAssertEqual(try Self.remoteLinkText(root + "/dest/folder/up"), "../target.txt")
        XCTAssertEqual(try Self.remoteLinkText(root + "/dest/folder/self"), "self")
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/target.txt"))"), "keep")
    }

    @MainActor
    func testSameHostMoveOfLinkRenamesLink() async throws {
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH("cd \(Self.shellQuote(root)) && printf keep > target.txt && ln -s target.txt link && mkdir dest")
        let link = Location.remote(hostID: session.hostID, path: root + "/link")
        let dest = Location.remote(hostID: session.hostID, path: root + "/dest")

        let moved = try await FileOperationQueue.shared.move(items: [link], to: dest)

        XCTAssertEqual(moved, [dest.appendingPathComponent("link")])
        XCTAssertEqual(try Self.remoteLinkText(root + "/dest/link"), "target.txt")
        XCTAssertFalse(try Self.remoteIsLink(root + "/link"))
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/target.txt"))"), "keep")
    }

    @MainActor
    func testTrashingRemoteLinkLeavesTarget() async throws {
        RemoteTrashExplainer.markDismissed()
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH(
            "cd \(Self.shellQuote(root)) && printf keep > target.txt && ln -s target.txt valid && ln -s missing.txt dangling"
        )
        let valid = Location.remote(hostID: session.hostID, path: root + "/valid")
        let dangling = Location.remote(hostID: session.hostID, path: root + "/dangling")
        let undoManager = UndoManager()

        try await FileOperationQueue.shared.delete(items: [valid, dangling], undoManager: undoManager)

        XCTAssertFalse(try Self.remoteIsLink(root + "/valid"))
        XCTAssertFalse(try Self.remoteIsLink(root + "/dangling"))
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/target.txt"))"), "keep")

        undoManager.undo()
        try await Self.waitForRemotePath(root + "/valid")
        XCTAssertEqual(try Self.remoteLinkText(root + "/valid"), "target.txt")
        XCTAssertEqual(try Self.remoteLinkText(root + "/dangling"), "missing.txt")
    }

    @MainActor
    func testFileLinkUploadsTargetUnderLinkName() async throws {
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH("mkdir \(Self.shellQuote(root + "/dest"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        _ = try createTestFile(in: localRoot, name: "target.txt", content: "through the link")
        let link = localRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
        let dest = Location.remote(hostID: session.hostID, path: root + "/dest")

        let copied = try await FileOperationQueue.shared.copy(items: [.local(link)], to: dest)

        XCTAssertEqual(copied, [dest.appendingPathComponent("link")])
        XCTAssertTrue(try Self.remoteIsRegularFile(root + "/dest/link"))
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/dest/link"))"), "through the link")
    }

    @MainActor
    func testFolderLinkDownloadsFolderUnderLinkName() async throws {
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH(
            "cd \(Self.shellQuote(root)) && mkdir dir && printf inner > dir/a.txt && ln -s a.txt dir/inner && ln -s dir dirlink"
        )
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let localDest = try createTestFolder(in: localRoot, name: "dest")
        let dirlink = Location.remote(hostID: session.hostID, path: root + "/dirlink")

        let copied = try await FileOperationQueue.shared.copy(items: [dirlink], to: .local(localDest))

        let landed = localDest.appendingPathComponent("dirlink")
        XCTAssertEqual(copied, [.local(landed)])
        XCTAssertFalse(Self.localIsLink(landed))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: landed.appendingPathComponent("a.txt"), encoding: .utf8), "inner")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: landed.appendingPathComponent("inner").path),
            "a.txt"
        )
    }

    @MainActor
    func testFolderWithInsideAndOutsideLinksUploadsPerRule() async throws {
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH("mkdir \(Self.shellQuote(root + "/dest"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        _ = try createTestFile(in: localRoot, name: "outside.txt", content: "outside body")
        let folder = try createTestFolder(in: localRoot, name: "folder")
        let data = try createTestFolder(in: folder, name: "data")
        _ = try createTestFile(in: data, name: "file.txt", content: "inside body")
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("inside").path,
            withDestinationPath: data.appendingPathComponent("file.txt").path
        )
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("outside").path,
            withDestinationPath: "../outside.txt"
        )
        let dest = Location.remote(hostID: session.hostID, path: root + "/dest")

        let copied = try await FileOperationQueue.shared.copy(items: [.local(folder)], to: dest)

        XCTAssertEqual(copied, [dest.appendingPathComponent("folder")])
        XCTAssertEqual(try Self.remoteLinkText(root + "/dest/folder/inside"), "data/file.txt")
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/dest/folder/inside"))"), "inside body")
        XCTAssertTrue(try Self.remoteIsRegularFile(root + "/dest/folder/outside"))
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/dest/folder/outside"))"), "outside body")
    }

    @MainActor
    func testLoopingLinkFailsItemAndCompletesFolder() async throws {
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH("mkdir \(Self.shellQuote(root + "/dest"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let folder = try createTestFolder(in: localRoot, name: "folder")
        _ = try createTestFile(in: folder, name: "ok.txt", content: "ok")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("self").path, withDestinationPath: ".")
        let dest = Location.remote(hostID: session.hostID, path: root + "/dest")

        do {
            _ = try await FileOperationQueue.shared.copy(items: [.local(folder)], to: dest)
            XCTFail("Expected the looping link to be reported")
        } catch FileOperationError.partialFailure(let succeeded, let failed) {
            XCTAssertEqual(succeeded.map(\.path), [root + "/dest/folder"])
            XCTAssertEqual(
                failed.map { Self.parentResolvedPath($0.0) },
                [folder.resolvingSymlinksInPath().appendingPathComponent("self").path]
            )
            let remote = try XCTUnwrap(failed.first?.1 as? RemoteOperationError)
            XCTAssertEqual(remote.underlying.localizedDescription, "The link self leads in a loop.")
        }

        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/dest/folder/ok.txt"))"), "ok")
        XCTAssertFalse(try Self.remoteIsLink(root + "/dest/folder/self"))
        XCTAssertFalse(try Self.remotePathExists(root + "/dest/folder/self"))
    }

    @MainActor
    func testDanglingLinkFailsItemOnly() async throws {
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH("mkdir \(Self.shellQuote(root + "/dest"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let plain = try createTestFile(in: localRoot, name: "plain.txt", content: "plain")
        let dangling = localRoot.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing.txt")
        let dest = Location.remote(hostID: session.hostID, path: root + "/dest")

        do {
            _ = try await FileOperationQueue.shared.copy(items: [.local(dangling), .local(plain)], to: dest)
            XCTFail("Expected the dangling link to be reported")
        } catch FileOperationError.partialFailure(let succeeded, let failed) {
            XCTAssertEqual(succeeded.map(\.path), [root + "/dest/plain.txt"])
            XCTAssertEqual(failed.map(\.0.path), [dangling.path])
            let remote = try XCTUnwrap(failed.first?.1 as? RemoteOperationError)
            XCTAssertEqual(
                remote.underlying.localizedDescription,
                "The link dangling points to an item that does not exist."
            )
        }

        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/dest/plain.txt"))"), "plain")
        XCTAssertFalse(try Self.remoteIsLink(root + "/dest/dangling"))
    }

    @MainActor
    func testCrossHostMoveOfLinkTrashesLinkOnly() async throws {
        let session = try await makeQueueSession()
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: session.hostID) }
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH("mkdir \(Self.shellQuote(root + "/dest"))")
        let localRoot = try createTempDirectory()
        defer { cleanupTempDirectory(localRoot) }
        let target = try createTestFile(in: localRoot, name: "target.txt", content: "stays local")
        let linkName = "link-" + UUID().uuidString.lowercased()
        let link = localRoot.appendingPathComponent(linkName)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let dest = Location.remote(hostID: session.hostID, path: root + "/dest")

        let moved = try await FileOperationQueue.shared.move(items: [.local(link)], to: dest)

        XCTAssertEqual(moved, [dest.appendingPathComponent(linkName)])
        XCTAssertTrue(try Self.remoteIsRegularFile(root + "/dest/" + linkName))
        XCTAssertEqual(try Self.runSSH("cat \(Self.shellQuote(root + "/dest/" + linkName))"), "stays local")
        XCTAssertFalse(PathProbe.existsWithoutFollowing(link.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "stays local")
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let trashedLink = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: trash.path).first { $0.hasPrefix(linkName) },
            "The link itself goes to the Trash"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: trash.appendingPathComponent(trashedLink).path),
            target.path
        )
        try? FileManager.default.removeItem(at: trash.appendingPathComponent(trashedLink))
    }

    func testLegacySymlinkCreationRefusesThroughRealHelper() async throws {
        let session = try await RemoteIntegrationSession.make()
        let root = try Self.makeRemoteFixtureRoot()
        defer { Self.cleanupRemote(root) }
        try Self.runSSH("cd \(Self.shellQuote(root)) && printf t > target.txt")
        let remote = { (name: String) in Location.remote(hostID: session.hostID, path: root + "/" + name) }

        do {
            try await session.provider.createSymbolicLink(at: remote("new"), targetPath: "target.txt")
            XCTFail("Legacy symlink creation must refuse before changing files")
        } catch {
            // The compatibility refusal is the contract now.
        }
        XCTAssertFalse(try Self.remoteIsLink(root + "/new"))
        XCTAssertTrue(try Self.remoteIsRegularFile(root + "/target.txt"))
    }
}
