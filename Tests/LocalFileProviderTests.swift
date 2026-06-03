import XCTest
@testable import Detours

final class LocalFileProviderTests: XCTestCase {
    func testListReturnsExpectedEntries() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFile(in: temp, name: "a.txt", content: "hello")
        _ = try createTestFolder(in: temp, name: "Folder")

        let providerEntries = try await LocalFileProvider.shared.list(.local(temp), showHidden: false)
        let loaderEntries = try await DirectoryLoader.shared.loadDirectory(temp, showHidden: false)

        XCTAssertEqual(Set(providerEntries.map(\.name)), Set(loaderEntries.map(\.name)))
    }

    func testCopyAndMoveBehaviour() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "a.txt", content: "hello")
        let copyDestination = try createTestFolder(in: temp, name: "CopyDest")
        let moveDestination = try createTestFolder(in: temp, name: "MoveDest")

        let copied = try await LocalFileProvider.shared.copy([.local(source)], to: .local(copyDestination))
        XCTAssertEqual(copied, [.local(copyDestination.appendingPathComponent("a.txt"))])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied[0].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let moved = try await LocalFileProvider.shared.move(copied, to: .local(moveDestination))
        XCTAssertEqual(moved, [.local(moveDestination.appendingPathComponent("a.txt"))])
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved[0].url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied[0].url.path))
    }
}
