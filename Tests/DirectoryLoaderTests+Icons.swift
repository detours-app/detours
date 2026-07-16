import AppKit
import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Detours

@Suite("IconLoader Tests")
struct IconLoaderTests {

    @Test("Second call for same URL returns cached icon without re-fetching")
    func testIconLoaderCachesResults() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("icon_test.txt")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = IconLoader()
        let icon1 = await loader.icon(for: fileURL, isDirectory: false, isPackage: false)
        let icon2 = await loader.icon(for: fileURL, isDirectory: false, isPackage: false)

        // Both should be the same object (cached)
        #expect(icon1 === icon2)
    }

    @Test("invalidate removes entry, next call re-fetches")
    func testIconLoaderInvalidation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("icon_test")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = IconLoader()
        let icon1 = await loader.icon(for: fileURL, isDirectory: false, isPackage: false)
        #expect(icon1 !== IconLoader.placeholderFileIcon)

        await loader.invalidate(fileURL)

        let icon2 = await loader.icon(
            for: fileURL,
            isDirectory: false,
            isPackage: false,
            isNetworkVolume: true
        )

        // The network route returns the placeholder for an extensionless path.
        // A no-op invalidation would return the cached local workspace icon.
        #expect(icon2 === IconLoader.placeholderFileIcon)
    }
}

// MARK: - Extension-Based Icon Loading Tests

@Suite("IconLoader Network Volume Icons")
struct IconLoaderNetworkVolumeTests {

    @Test("Network volume directory returns folder placeholder icon")
    func testNetworkDirectoryGetsFolderIcon() async {
        let url = URL(fileURLWithPath: "/Volumes/share/SomeFolder")
        let loader = IconLoader()
        let icon = await loader.icon(for: url, isDirectory: true, isPackage: false, isNetworkVolume: true)
        #expect(icon === IconLoader.placeholderFolderIcon)
    }

    @Test("Network volume file with known extension returns UTType icon")
    func testNetworkFileGetsExtensionIcon() async {
        let url = URL(fileURLWithPath: "/Volumes/share/document.pdf")
        let loader = IconLoader()
        let icon = await loader.icon(for: url, isDirectory: false, isPackage: false, isNetworkVolume: true)

        #expect(icon !== IconLoader.placeholderFileIcon)
        #expect(icon.size.width > 0)
        #expect(icon.size.height > 0)
    }

    @Test("Network volume file without extension returns file placeholder")
    func testNetworkFileNoExtensionGetsPlaceholder() async {
        let url = URL(fileURLWithPath: "/Volumes/share/Makefile")
        let loader = IconLoader()
        let icon = await loader.icon(for: url, isDirectory: false, isPackage: false, isNetworkVolume: true)
        #expect(icon === IconLoader.placeholderFileIcon)
    }

    @Test("Network volume package returns UTType icon, not folder")
    func testNetworkPackageGetsExtensionIcon() async {
        let url = URL(fileURLWithPath: "/Volumes/share/presentation.key")
        let loader = IconLoader()
        let icon = await loader.icon(for: url, isDirectory: true, isPackage: true, isNetworkVolume: true)

        // Packages should get extension-based icon, not folder placeholder
        #expect(icon !== IconLoader.placeholderFolderIcon)
    }

    @Test("Network volume icons are cached")
    func testNetworkIconsCached() async {
        let url = URL(fileURLWithPath: "/Volumes/share/photo.jpg")
        let loader = IconLoader()
        let icon1 = await loader.icon(for: url, isDirectory: false, isPackage: false, isNetworkVolume: true)
        let icon2 = await loader.icon(for: url, isDirectory: false, isPackage: false, isNetworkVolume: true)
        #expect(icon1 === icon2)
    }

    @Test("Local extensionless file uses workspace lookup, not the network placeholder branch")
    func testLocalFileUsesWorkspaceLookup() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("executable")
        try "#!/bin/sh\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)

        let loader = IconLoader()
        let icon = await loader.icon(for: fileURL, isDirectory: false, isPackage: false, isNetworkVolume: false)

        // The extension-based branch returns this singleton for an extensionless
        // path. The local branch must ask NSWorkspace about the actual file.
        #expect(icon !== IconLoader.placeholderFileIcon)
    }
}

@Suite("Icon Load Task Lifecycle Tests")
struct IconLoadLifecycleTests {

    @Test("IconLoader invalidateAll clears entire cache")
    func testInvalidateAllClearsCache() async {
        let loader = IconLoader()

        // Load a few icons
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url1 = tempDir.appendingPathComponent("a")
        let url2 = tempDir.appendingPathComponent("b")
        let url3 = tempDir.appendingPathComponent("c")
        FileManager.default.createFile(atPath: url1.path, contents: Data())
        FileManager.default.createFile(atPath: url2.path, contents: Data())
        FileManager.default.createFile(atPath: url3.path, contents: Data())

        let cached1 = await loader.icon(for: url1, isDirectory: false, isPackage: false)
        let cached2 = await loader.icon(for: url2, isDirectory: false, isPackage: false)
        let cached3 = await loader.icon(for: url3, isDirectory: false, isPackage: false)
        #expect(cached1 !== IconLoader.placeholderFileIcon)
        #expect(cached2 !== IconLoader.placeholderFileIcon)
        #expect(cached3 !== IconLoader.placeholderFileIcon)

        // Invalidate all
        await loader.invalidateAll()

        let fresh1 = await loader.icon(for: url1, isDirectory: false, isPackage: false, isNetworkVolume: true)
        let fresh2 = await loader.icon(for: url2, isDirectory: false, isPackage: false, isNetworkVolume: true)
        let fresh3 = await loader.icon(for: url3, isDirectory: false, isPackage: false, isNetworkVolume: true)
        #expect(fresh1 === IconLoader.placeholderFileIcon)
        #expect(fresh2 === IconLoader.placeholderFileIcon)
        #expect(fresh3 === IconLoader.placeholderFileIcon)
    }

    @Test("DirectoryLoader loadChildren is equivalent to loadDirectory")
    func testLoadChildrenMatchesLoadDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("sub"),
            withIntermediateDirectories: false
        )

        let loader = DirectoryLoader()
        let dirEntries = try await loader.loadDirectory(tempDir, showHidden: false)
        let childEntries = try await loader.loadChildren(tempDir, showHidden: false)

        #expect(dirEntries.count == childEntries.count)
        #expect(Set(dirEntries.map(\.name)) == Set(childEntries.map(\.name)))
    }

    @Test("DirectoryLoader handles nonexistent directory")
    func testLoadDirectoryNonexistent() async throws {
        let loader = DirectoryLoader()
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        do {
            _ = try await loader.loadDirectory(fakeURL, showHidden: false, timeout: .seconds(5))
            Issue.record("Expected error for nonexistent directory")
        } catch let error as DirectoryLoadError {
            // Local nonexistent directory returns .notFound (ENOENT)
            #expect(error == .notFound)
        }
    }
}
