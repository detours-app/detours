import AppKit
import XCTest
@testable import Detours

@MainActor
final class ClipboardManagerTests: XCTestCase {
    private var previousItems: [NSPasteboardItem] = []

    override func setUp() async throws {
        try await super.setUp()
        previousItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                }
            }
            return clone
        }
        ClipboardManager.shared.clear()
    }

    override func tearDown() async throws {
        NSPasteboard.general.clearContents()
        if !previousItems.isEmpty {
            NSPasteboard.general.writeObjects(previousItems)
        }
        try await super.tearDown()
    }

    func testCopyWritesToPasteboard() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.copy(items: [file])

        let items = ClipboardManager.shared.items
        XCTAssertEqual(items, [file])
    }

    func testCutSetsIsCutFlag() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.isCut)
    }

    func testCopyClearsIsCutFlag() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])
        ClipboardManager.shared.copy(items: [file])

        XCTAssertFalse(ClipboardManager.shared.isCut)
    }

    func testHasItemsTrue() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.copy(items: [file])
        XCTAssertTrue(ClipboardManager.shared.hasItems)
    }

    func testHasItemsFalse() {
        XCTAssertFalse(ClipboardManager.shared.hasItems)
    }

    func testClearResetsState() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])
        ClipboardManager.shared.clear()

        XCTAssertFalse(ClipboardManager.shared.isCut)
        XCTAssertFalse(ClipboardManager.shared.hasItems)
    }

    func testCutPopulatesCutItemURLs() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.cutItemURLs.contains(file))
    }

    func testIsItemCut() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.isItemCut(file))
        XCTAssertFalse(ClipboardManager.shared.isItemCut(temp))
    }

    func testCopyRemoteLocationsKeepsInternalClipboardState() {
        let location = Location.remote(hostID: UUID(), path: "/home/marco/file.txt")

        ClipboardManager.shared.copy(items: [location])

        XCTAssertEqual(ClipboardManager.shared.locations, [location])
        XCTAssertTrue(ClipboardManager.shared.hasItems)
        XCTAssertTrue(ClipboardManager.shared.hasValidLocations)
        XCTAssertTrue(ClipboardManager.shared.items.isEmpty)
        XCTAssertFalse(ClipboardManager.shared.isCut)
    }

    func testCutRemoteLocationsSetsCutFlagWithoutLocalURLs() {
        let location = Location.remote(hostID: UUID(), path: "/home/marco/file.txt")

        ClipboardManager.shared.cut(items: [location])

        XCTAssertEqual(ClipboardManager.shared.locations, [location])
        XCTAssertTrue(ClipboardManager.shared.isCut)
        XCTAssertTrue(ClipboardManager.shared.cutItemURLs.isEmpty)
    }

    func testExternalPasteboardWriteInvalidatesRemoteClipboardState() {
        let location = Location.remote(hostID: UUID(), path: "/home/marco/file.txt")
        ClipboardManager.shared.cut(items: [location])

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("external", forType: .string)

        XCTAssertFalse(ClipboardManager.shared.isCut)
        XCTAssertFalse(ClipboardManager.shared.hasItems)
        XCTAssertTrue(ClipboardManager.shared.locations.isEmpty)
    }

    func testRemoteCutLocationsRemainRetryableUntilSuccess() async throws {
        let hostID = UUID()
        let source = Location.remote(hostID: hostID, path: "/Source/file.txt")
        let destination = Location.remote(hostID: hostID, path: "/Destination")
        let moved = Location.remote(hostID: hostID, path: "/Destination/file.txt")
        let provider = RetryableCutProvider(movedLocation: moved)
        FileOperationQueue.shared.registerRemoteFileProvider(provider, for: hostID)
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: hostID) }
        ClipboardManager.shared.cut(items: [source])

        do {
            _ = try await ClipboardManager.shared.paste(to: destination)
            XCTFail("The first controlled move should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Controlled move failure")
        }

        XCTAssertTrue(ClipboardManager.shared.isCut)
        XCTAssertEqual(ClipboardManager.shared.locations, [source])
        XCTAssertEqual(ClipboardManager.shared.cutItemLocations, Set([source]))

        let result = try await ClipboardManager.shared.paste(to: destination)

        XCTAssertEqual(result, [moved])
        XCTAssertFalse(ClipboardManager.shared.isCut)
        XCTAssertTrue(ClipboardManager.shared.locations.isEmpty)
        XCTAssertTrue(ClipboardManager.shared.cutItemLocations.isEmpty)
        let moveCallCount = await provider.moveCallCount()
        XCTAssertEqual(moveCallCount, 2)
    }
}

private actor RetryableCutProvider: FileProvider {
    private let movedLocation: Location
    private var moveCalls = 0

    init(movedLocation: Location) {
        self.movedLocation = movedLocation
    }

    func moveCallCount() -> Int { moveCalls }
    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] { [] }
    func stat(_ location: Location) async throws -> LoadedFileEntry { throw FileProviderError.unsupportedOperation("stat") }
    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        moveCalls += 1
        if moveCalls == 1 {
            throw FileProviderError.unsupportedOperation("Controlled move failure")
        }
        return [movedLocation]
    }
    func delete(_ items: [Location]) async throws {}
    func trash(_ items: [Location]) async throws -> [TrashedItem] { [] }
    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] { [] }
    func rename(_ item: Location, to newName: String) async throws -> Location { item }
    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location { items[0] }
    func archiveExtract(_ archive: Location, password: String?) async throws -> Location { archive }
    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        FileProviderWatch(id: UUID(), location: location)
    }
    func unwatch(_ watch: FileProviderWatch) async {}
    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func readSymlink(_ location: Location) async throws -> Location { location }
    func openForQuickLook(_ location: Location) async throws -> URL { URL(fileURLWithPath: "/tmp/unused") }
}
