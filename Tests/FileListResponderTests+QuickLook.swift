import AppKit
import XCTest
@testable import Detours

extension FileListResponderTests {
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
