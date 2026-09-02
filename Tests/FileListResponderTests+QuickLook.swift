import AppKit
import XCTest
@testable import Detours

extension FileListResponderTests {
    func testSelectingRemoteFolderClosesDetoursPreviewWithoutLeavingSpinner() async throws {
        let hostID = UUID()
        let rootPath = "/home/marco"
        let folderPath = "\(rootPath)/reports"
        let provider = FileListRemoteProvider(
            hostID: hostID,
            listings: [
                rootPath: [
                    LoadedFileEntry(
                        location: .remote(hostID: hostID, path: folderPath),
                        url: URL(fileURLWithPath: folderPath),
                        name: "reports",
                        isDirectory: true
                    ),
                ],
                folderPath: [],
            ]
        )
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        let host = RemoteHost(id: hostID, displayName: "Dev VM", sshTarget: "dev")
        viewController.loadRemoteDirectory(host: host, path: rootPath, provider: provider)
        let loaded = await waitForRowCount(1, in: viewController.tableView)
        XCTAssertTrue(loaded)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let preview = DetoursPreviewWindowController(theme: .dark)
        preview.prepare(title: "previous.txt", theme: .dark)
        viewController.detoursPreviewWindow = preview
        XCTAssertTrue(preview.isPresented)

        viewController.refreshQuickLookPanel()

        XCTAssertFalse(preview.isPresented, "A remote folder cannot be previewed and must close the file preview")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(preview.isShowingSpinner, "The abandoned folder selection must not raise a delayed spinner")
        XCTAssertFalse(viewController.quickLookGenerationTaskIsActiveForTesting)
    }

    func testRemoteSymlinkQuickLookPreviewsTheLinkedFile() async throws {
        let hostID = UUID()
        let linkPath = "/home/marco/current"
        let targetPath = "/home/marco/releases/config-2026.yaml"
        let provider = FileListRemoteProvider(
            hostID: hostID,
            listings: [
                "/home/marco": [
                    LoadedFileEntry(
                        location: .remote(hostID: hostID, path: linkPath),
                        url: URL(fileURLWithPath: linkPath),
                        name: "current",
                        isDirectory: false,
                        isSymbolicLink: true,
                        fileSize: 512
                    ),
                ],
                "/home/marco/releases": [
                    LoadedFileEntry(
                        location: .remote(hostID: hostID, path: targetPath),
                        url: URL(fileURLWithPath: targetPath),
                        name: "config-2026.yaml",
                        isDirectory: false,
                        fileSize: 512
                    ),
                ],
            ],
            symlinks: [linkPath: targetPath]
        )
        let link = FileItem(
            entry: LoadedFileEntry(
                location: .remote(hostID: hostID, path: linkPath),
                url: URL(fileURLWithPath: linkPath),
                name: "current",
                isDirectory: false,
                isSymbolicLink: true,
                fileSize: 512
            ),
            icon: NSImage()
        )
        let viewController = FileListViewController()

        let source = try await viewController.resolveRemoteQuickLookSource(for: link, provider: provider)

        XCTAssertEqual(source.location, .remote(hostID: hostID, path: targetPath), "Download the file the link points at")
        XCTAssertEqual(source.name, "config-2026.yaml", "The target's name carries the extension the preview needs")
        XCTAssertFalse(source.entry.isDirectory)
        XCTAssertEqual(source.entry.fileSize, 512)
    }

    func testRemoteSymlinkToFolderReportsTheFolderSoQuickLookCanDecline() async throws {
        let hostID = UUID()
        let linkPath = "/home/marco/latest"
        let targetPath = "/home/marco/builds/2026-09"
        let provider = FileListRemoteProvider(
            hostID: hostID,
            listings: ["/home/marco": [], targetPath: []],
            symlinks: [linkPath: targetPath]
        )
        let link = FileItem(
            entry: LoadedFileEntry(
                location: .remote(hostID: hostID, path: linkPath),
                url: URL(fileURLWithPath: linkPath),
                name: "latest",
                isDirectory: false,
                isSymbolicLink: true
            ),
            icon: NSImage()
        )
        let viewController = FileListViewController()

        let source = try await viewController.resolveRemoteQuickLookSource(for: link, provider: provider)

        XCTAssertEqual(source.location, .remote(hostID: hostID, path: targetPath))
        XCTAssertTrue(source.entry.isDirectory, "A link to a folder must surface as a folder, not a zero-byte file")
    }

    func testPlainRemoteFileQuickLookKeepsItsOwnLocation() async throws {
        let hostID = UUID()
        let filePath = "/home/marco/notes.txt"
        let provider = FileListRemoteProvider(
            hostID: hostID,
            listings: [
                "/home/marco": [
                    LoadedFileEntry(
                        location: .remote(hostID: hostID, path: filePath),
                        url: URL(fileURLWithPath: filePath),
                        name: "notes.txt",
                        isDirectory: false,
                        fileSize: 10
                    ),
                ],
            ]
        )
        let file = FileItem(
            entry: LoadedFileEntry(
                location: .remote(hostID: hostID, path: filePath),
                url: URL(fileURLWithPath: filePath),
                name: "notes.txt",
                isDirectory: false,
                fileSize: 10
            ),
            icon: NSImage()
        )
        let viewController = FileListViewController()

        let source = try await viewController.resolveRemoteQuickLookSource(for: file, provider: provider)

        XCTAssertEqual(source.location, .remote(hostID: hostID, path: filePath))
        XCTAssertEqual(source.name, "notes.txt")
    }

    func testRemoteQuickLookReportsNoPreviewItemUntilDownloadCompletes() {
        XCTAssertEqual(
            FileListViewController.quickLookPreviewItemCount(
                remoteRequestActive: true,
                remotePreviewReady: false,
                selectedURLCount: 1
            ),
            0
        )
    }

    func testRemoteQuickLookReportsPreviewItemAfterDownloadCompletes() {
        XCTAssertEqual(
            FileListViewController.quickLookPreviewItemCount(
                remoteRequestActive: true,
                remotePreviewReady: true,
                selectedURLCount: 0
            ),
            1
        )
    }

    func testGeneratedRemotePreviewUsesTheDetoursWindow() {
        let source = URL(fileURLWithPath: "/tmp/remote-note.md")
        let generated = URL(fileURLWithPath: "/tmp/generated/preview.html")

        XCTAssertTrue(FileListViewController.usesDetoursPreview(previewURL: generated, sourceURL: source))
    }

    func testRemoteImageUsesTheDetoursWindowWithoutGeneration() {
        let image = URL(fileURLWithPath: "/tmp/remote-image.png")

        XCTAssertTrue(FileListViewController.usesDetoursPreview(previewURL: image, sourceURL: image))
    }

    func testSystemPreviewIsOfferedOnlyWhileADetoursPreviewIsShowing() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "note.txt")
        let generated = temp.appendingPathComponent("generated-preview.html")
        let viewController = FileListViewController()
        viewController.quickLookPreviewGenerator = FakeQuickLookPreviewGenerator(results: [source: generated])

        XCTAssertFalse(viewController.canOpenInSystemPreview, "Nothing to hand over before a preview opens")

        viewController.startLocalQuickLookGenerationForTesting(urls: [source])
        let completed = await waitForQuickLookGeneration(in: viewController)
        XCTAssertTrue(completed)

        XCTAssertTrue(viewController.canOpenInSystemPreview)
        XCTAssertEqual(viewController.detoursPreviewSourceURL, source, "The file itself, not the document drawn from it")

        viewController.closeDetoursPreviewWindow()
        XCTAssertFalse(viewController.canOpenInSystemPreview)
        XCTAssertNil(viewController.detoursPreviewSourceURL)
    }

    func testPDFKeepsTheSystemViewerForItsPageThumbnails() {
        let document = URL(fileURLWithPath: "/tmp/report.pdf")

        XCTAssertFalse(FileListViewController.usesDetoursPreview(previewURL: document, sourceURL: document))
    }

    func testUnsupportedRemoteFileKeepsTheSystemViewerFallback() {
        let archive = URL(fileURLWithPath: "/tmp/remote-archive.zip")

        XCTAssertFalse(FileListViewController.usesDetoursPreview(previewURL: archive, sourceURL: archive))
    }

    func testLocalQuickLookUsesSelectedURLsWhenNoRemoteRequestIsActive() {
        XCTAssertEqual(
            FileListViewController.quickLookPreviewItemCount(
                remoteRequestActive: false,
                remotePreviewReady: false,
                selectedURLCount: 3
            ),
            3
        )
    }

    func testLocalQuickLookUsesGeneratedPreviewForSupportedTextFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "note.txt")
        let generated = temp.appendingPathComponent("generated-preview.html")
        let viewController = FileListViewController()
        viewController.quickLookPreviewGenerator = FakeQuickLookPreviewGenerator(results: [source: generated])

        viewController.startLocalQuickLookGenerationForTesting(urls: [source])
        let completed = await waitForQuickLookGeneration(in: viewController)

        XCTAssertTrue(completed)
        XCTAssertEqual(viewController.quickLookPreviewURLsForTesting, [generated])
        XCTAssertEqual(
            FileListViewController.quickLookPreviewItemCount(
                remoteRequestActive: false,
                remotePreviewReady: false,
                selectedURLCount: 1,
                generatedPreviewCount: viewController.quickLookPreviewURLsForTesting.count
            ),
            1
        )
    }

    func testQuickLookKeepsTheCurrentPreviewWhileTheNextOneIsBuilt() {
        // Reporting nothing here empties the panel for as long as generation takes, which is seen
        // as a white flash when moving from file to file.
        XCTAssertEqual(
            FileListViewController.quickLookPreviewItemCount(
                remoteRequestActive: false,
                remotePreviewReady: false,
                selectedURLCount: 1,
                generatedPreviewCount: 1,
                generationActive: true
            ),
            1
        )
    }

    func testQuickLookShowsNothingWhileTheFirstPreviewIsBuilt() {
        // With nothing generated yet there is nothing to hold on to, and the selected file must not
        // be handed over raw, or the panel draws a system preview before the Detours one arrives.
        XCTAssertEqual(
            FileListViewController.quickLookPreviewItemCount(
                remoteRequestActive: false,
                remotePreviewReady: false,
                selectedURLCount: 1,
                generatedPreviewCount: 0,
                generationActive: true
            ),
            0
        )
    }

    func testLocalQuickLookTitleUsesOriginalFileNameNotGeneratedPreview() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "note.txt")
        let generated = temp.appendingPathComponent("preview.html")
        let viewController = FileListViewController()
        viewController.quickLookPreviewGenerator = FakeQuickLookPreviewGenerator(results: [source: generated])

        viewController.startLocalQuickLookGenerationForTesting(urls: [source])
        let completed = await waitForQuickLookGeneration(in: viewController)

        XCTAssertTrue(completed)
        XCTAssertEqual(viewController.quickLookPreviewTitlesForTesting, ["note.txt"])
    }

    func testRemoteQuickLookTitleUsesRemoteFileNameNotGeneratedPreview() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let downloaded = try createTestFile(in: temp, name: "downloaded-cache-file")
        let generated = temp.appendingPathComponent("preview.html")
        let viewController = FileListViewController()
        viewController.quickLookPreviewGenerator = FakeQuickLookPreviewGenerator(results: [downloaded: generated])

        try await viewController.prepareRemoteQuickLookPreviewForTesting(downloadedURL: downloaded, displayName: "notes.txt")

        XCTAssertEqual(viewController.quickLookPreviewTitlesForTesting, ["notes.txt"])
    }

    func testLocalQuickLookKeepsOriginalURLForUnsupportedFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "image.png")
        let viewController = FileListViewController()
        viewController.quickLookPreviewGenerator = FakeQuickLookPreviewGenerator(results: [source: source])

        viewController.startLocalQuickLookGenerationForTesting(urls: [source])
        let completed = await waitForQuickLookGeneration(in: viewController)

        XCTAssertTrue(completed)
        XCTAssertEqual(viewController.quickLookPreviewURLsForTesting, [source])
    }

    func testRemoteQuickLookGeneratesPreviewAfterDownload() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let downloaded = try createTestFile(in: temp, name: "remote.md")
        let generated = temp.appendingPathComponent("remote-generated.html")
        let viewController = FileListViewController()
        viewController.quickLookPreviewGenerator = FakeQuickLookPreviewGenerator(results: [downloaded: generated])

        try await viewController.prepareRemoteQuickLookPreviewForTesting(downloadedURL: downloaded, displayName: "remote.md")

        XCTAssertEqual(viewController.quickLookPreviewURLsForTesting, [generated])
    }

    func testQuickLookSelectionChangeCancelsPreviewGeneration() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let first = try createTestFile(in: temp, name: "first.txt")
        let second = try createTestFile(in: temp, name: "second.txt")
        let firstPreview = temp.appendingPathComponent("first-preview.html")
        let secondPreview = temp.appendingPathComponent("second-preview.html")
        let viewController = FileListViewController()
        viewController.quickLookPreviewGenerator = FakeQuickLookPreviewGenerator(
            results: [first: firstPreview, second: secondPreview],
            delayNanoseconds: 50_000_000
        )

        viewController.startLocalQuickLookGenerationForTesting(urls: [first])
        viewController.startLocalQuickLookGenerationForTesting(urls: [second])
        let completed = await waitForQuickLookGeneration(in: viewController)

        XCTAssertTrue(completed)
        XCTAssertEqual(viewController.quickLookPreviewURLsForTesting, [secondPreview])
    }
}
