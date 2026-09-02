import XCTest
@testable import detours_server

final class TrashOperationsTests: XCTestCase {
    func testTrashWritesInfoBeforeMovingFile() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }

        let source = try createTestFile(in: home, name: "notes.txt", content: "hello")
        let operations = TrashOperations(homeDirectory: home)

        let infoPaths = try operations.trash(paths: [source.path])

        XCTAssertEqual(infoPaths.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: infoPaths[0]))

        let info = try String(contentsOfFile: infoPaths[0], encoding: .utf8)
        XCTAssertTrue(info.contains("[Trash Info]"))
        XCTAssertTrue(info.contains("Path=\(source.path)"))

        let trashName = URL(fileURLWithPath: infoPaths[0]).deletingPathExtension().lastPathComponent
        let trashedFile = home
            .appendingPathComponent(".local/share/Trash/files")
            .appendingPathComponent(trashName)
        XCTAssertEqual(try String(contentsOf: trashedFile, encoding: .utf8), "hello")
    }

    func testTrashDirectoriesUse0700Permissions() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }

        let source = try createTestFile(in: home, name: "notes.txt")
        let operations = TrashOperations(homeDirectory: home)

        _ = try operations.trash(paths: [source.path])

        for relativePath in [
            ".local/share/Trash",
            ".local/share/Trash/files",
            ".local/share/Trash/info",
        ] {
            let url = home.appendingPathComponent(relativePath)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = attrs[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o700)
        }
    }

    func testServerTrashRollsBackEarlierItemsWhenLaterItemIsMissing() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let source = try createTestFile(in: home, name: "notes.txt", content: "preserve me")
        let missing = home.appendingPathComponent("missing.txt")
        let operations = FileOperations(
            trashOperations: TrashOperations(homeDirectory: home)
        )

        XCTAssertThrowsError(
            try operations.trash(items: [
                ServerRemotePath(source.path),
                ServerRemotePath(missing.path),
            ])
        ) { error in
            XCTAssertEqual(error as? TrashOperationsError, .missingItem(missing.path))
        }

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "preserve me")
        let trashFiles = home.appendingPathComponent(".local/share/Trash/files")
        let trashInfo = home.appendingPathComponent(".local/share/Trash/info")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashFiles.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashInfo.path), [])
    }

    func testRestoreReadsOriginalPathFromTrashInfo() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }

        let folder = try createTestFolder(in: home, name: "Project")
        let source = try createTestFile(in: folder, name: "notes.txt", content: "hello")
        let operations = TrashOperations(homeDirectory: home)

        let infoPaths = try operations.trash(paths: [source.path])
        let restoredPaths = try operations.restore(trashInfoPaths: infoPaths)

        XCTAssertEqual(restoredPaths, [source.path])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: infoPaths[0]))
    }

    func testTrashingLinkMovesLinkNotTarget() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let target = try createTestFile(in: home, name: "target.txt", content: "stay")
        let valid = home.appendingPathComponent("valid")
        let dangling = home.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: valid.path, withDestinationPath: "target.txt")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing.txt")
        let operations = TrashOperations(homeDirectory: home)

        let infoPaths = try operations.trash(paths: [valid.path, dangling.path])

        XCTAssertEqual(infoPaths.count, 2)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "stay")
        XCTAssertFalse(PathProbe.existsWithoutFollowing(valid.path))
        XCTAssertFalse(PathProbe.existsWithoutFollowing(dangling.path))
        let trashed = infoPaths.map { info in
            home.appendingPathComponent(".local/share/Trash/files")
                .appendingPathComponent(URL(fileURLWithPath: info).deletingPathExtension().lastPathComponent)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: trashed[0].path), "target.txt")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: trashed[1].path), "missing.txt")
    }

    func testRestorePathsPreserveLink() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        _ = try createTestFile(in: home, name: "target.txt", content: "stay")
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
        let operations = TrashOperations(homeDirectory: home)

        let infoPaths = try operations.trash(paths: [link.path])
        XCTAssertFalse(PathProbe.existsWithoutFollowing(link.path))
        XCTAssertEqual(try operations.restore(trashInfoPaths: infoPaths), [link.path])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "target.txt")

        // Batch rollback: the second item is missing, so the first goes back as the link it was.
        XCTAssertThrowsError(try operations.trash(paths: [link.path, home.appendingPathComponent("absent").path]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "target.txt")
    }

    func testRestoreRefusesDestinationOutsideHome() throws {
        let home = try createTempDirectory()
        let outside = try createTempDirectory()
        defer {
            cleanupTempDirectory(home)
            cleanupTempDirectory(outside)
        }

        let operations = TrashOperations(homeDirectory: home)
        let source = try createTestFile(in: home, name: "notes.txt")
        let infoPaths = try operations.trash(paths: [source.path])
        let infoURL = URL(fileURLWithPath: infoPaths[0])
        let outsidePath = outside.appendingPathComponent("notes.txt").path
        let rewrittenInfo = """
        [Trash Info]
        Path=\(outsidePath)
        DeletionDate=2026-06-03T12:00:00

        """
        try rewrittenInfo.write(to: infoURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try operations.restore(trashInfoPaths: infoPaths)) { error in
            XCTAssertEqual(error as? TrashOperationsError, .restoreDestinationOutsideHome(outsidePath))
        }
    }
}
