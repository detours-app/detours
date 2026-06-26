import AppKit
import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Detours

@Suite("FileItem Entry Init Tests")
struct FileItemEntryInitTests {

    @Test("FileItem created from LoadedFileEntry has correct properties")
    @MainActor
    func testFileItemInitFromEntry() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("doc.txt")
        try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = DirectoryLoader()
        let entries = try await loader.loadDirectory(tempDir, showHidden: false)

        guard let entry = entries.first(where: { $0.name == "doc.txt" }) else {
            Issue.record("Expected entry for doc.txt")
            return
        }

        let icon = IconLoader.placeholderFileIcon
        let item = FileItem(entry: entry, icon: icon)

        #expect(item.name == "doc.txt")
        #expect(item.url.standardizedFileURL == fileURL.standardizedFileURL)
        #expect(item.isDirectory == false)
        #expect(item.isPackage == false)
        #expect(item.icon === icon)
        #expect(item.size != nil)
        #expect(item.iCloudStatus == .local)
    }
}

@Suite("Async Folder Expansion Tests")
struct AsyncFolderExpansionTests {

    @Test("loadChildrenAsync returns sorted children with parent set")
    @MainActor
    func testLoadChildrenAsyncReturnsChildren() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let subDir = tempDir.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: subDir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: subDir.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: subDir.appendingPathComponent("gamma"),
            withIntermediateDirectories: false
        )

        let parentItem = FileItem(
            name: "parent",
            url: subDir,
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: IconLoader.placeholderFolderIcon
        )

        let children = try await parentItem.loadChildrenAsync(showHidden: false)

        #expect(children != nil)
        #expect(children!.count == 3)

        // Folders should be first (sorted folders-first)
        #expect(children![0].name == "gamma")
        #expect(children![0].isDirectory == true)

        // All children should have parent set
        for child in children! {
            #expect(child.parent === parentItem)
        }
    }

    @Test("loadChildrenAsync returns existing children if already loaded")
    @MainActor
    func testLoadChildrenAsyncReturnsCached() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let subDir = tempDir.appendingPathComponent("cached")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: subDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let parentItem = FileItem(
            name: "cached",
            url: subDir,
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: IconLoader.placeholderFolderIcon
        )

        // Load once
        let first = try await parentItem.loadChildrenAsync(showHidden: false)
        // Load again - should return same objects
        let second = try await parentItem.loadChildrenAsync(showHidden: false)

        #expect(first!.count == second!.count)
        #expect(first![0] === second![0])
    }

    @Test("loadChildrenAsync returns nil for non-directory")
    @MainActor
    func testLoadChildrenAsyncNonDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("file.txt")
        try "data".write(to: fileURL, atomically: true, encoding: .utf8)

        let fileItem = FileItem(
            name: "file.txt",
            url: fileURL,
            isDirectory: false,
            size: 4,
            dateModified: Date(),
            icon: IconLoader.placeholderFileIcon
        )

        let result = try await fileItem.loadChildrenAsync(showHidden: false)
        #expect(result == nil)
    }
}
