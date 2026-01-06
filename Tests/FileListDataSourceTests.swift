import XCTest
@testable import Detour

@MainActor
final class FileListDataSourceTests: XCTestCase {
    func testLoadDirectory() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFile(in: temp, name: "a.txt")
        _ = try createTestFolder(in: temp, name: "Folder")

        let dataSource = FileListDataSource()
        dataSource.loadDirectory(temp)

        XCTAssertEqual(dataSource.items.count, 2)
    }

    func testLoadDirectoryExcludesHidden() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFile(in: temp, name: ".hidden")
        _ = try createTestFile(in: temp, name: "visible.txt")

        let dataSource = FileListDataSource()
        dataSource.loadDirectory(temp)

        XCTAssertEqual(dataSource.items.map { $0.name }, ["visible.txt"])
    }

    func testLoadDirectorySortsFoldersFirst() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFile(in: temp, name: "b.txt")
        _ = try createTestFolder(in: temp, name: "a-folder")

        let dataSource = FileListDataSource()
        dataSource.loadDirectory(temp)

        XCTAssertTrue(dataSource.items.first?.isDirectory == true)
    }

    func testLoadDirectorySortsAlphabetically() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFolder(in: temp, name: "b-folder")
        _ = try createTestFolder(in: temp, name: "a-folder")
        _ = try createTestFile(in: temp, name: "b.txt")
        _ = try createTestFile(in: temp, name: "a.txt")

        let dataSource = FileListDataSource()
        dataSource.loadDirectory(temp)

        let names = dataSource.items.map { $0.name }
        XCTAssertEqual(names, ["a-folder", "b-folder", "a.txt", "b.txt"])
    }

    func testLoadDirectoryHandlesEmptyDirectory() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let dataSource = FileListDataSource()
        dataSource.loadDirectory(temp)

        XCTAssertTrue(dataSource.items.isEmpty)
    }
}
