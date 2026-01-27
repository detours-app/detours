import XCTest
@testable import Detours

final class DuplicateStructureTests: XCTestCase {
    var tempDir: URL!
    var sourceDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create source directory structure for tests
        sourceDir = tempDir.appendingPathComponent("Source2025")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Directory Creation Tests

    func testDuplicateStructureCreatesDirectories() async throws {
        // Create nested folder structure
        let level1 = sourceDir.appendingPathComponent("Level1")
        let level2 = level1.appendingPathComponent("Level2")
        try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)

        let destination = tempDir.appendingPathComponent("Destination")

        let result = try await FileOperationQueue.shared.duplicateStructure(
            source: sourceDir,
            destination: destination,
            yearSubstitution: nil
        )

        XCTAssertEqual(result.path, destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Level1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Level1/Level2").path))
    }

    func testDuplicateStructurePreservesDepth() async throws {
        // Create 3-level deep structure
        let level1 = sourceDir.appendingPathComponent("A")
        let level2 = level1.appendingPathComponent("B")
        let level3 = level2.appendingPathComponent("C")
        try FileManager.default.createDirectory(at: level3, withIntermediateDirectories: true)

        let destination = tempDir.appendingPathComponent("Dest")

        _ = try await FileOperationQueue.shared.duplicateStructure(
            source: sourceDir,
            destination: destination,
            yearSubstitution: nil
        )

        // Verify all 3 levels exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("A").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("A/B").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("A/B/C").path))
    }

    func testDuplicateStructureOmitsFiles() async throws {
        // Create folder with a file inside
        let folder = sourceDir.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("file.txt")
        try "test content".write(to: file, atomically: true, encoding: .utf8)

        let destination = tempDir.appendingPathComponent("Dest")

        _ = try await FileOperationQueue.shared.duplicateStructure(
            source: sourceDir,
            destination: destination,
            yearSubstitution: nil
        )

        // Folder should exist, file should not
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Folder").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Folder/file.txt").path))
    }

    // MARK: - Year Substitution Tests

    func testDuplicateStructureYearSubstitution() async throws {
        // Create folder with year in name
        let folder2025 = sourceDir.appendingPathComponent("FY2025-Reports")
        try FileManager.default.createDirectory(at: folder2025, withIntermediateDirectories: true)

        let destination = tempDir.appendingPathComponent("Dest")

        _ = try await FileOperationQueue.shared.duplicateStructure(
            source: sourceDir,
            destination: destination,
            yearSubstitution: ("2025", "2026")
        )

        // Should have substituted year in folder name
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("FY2026-Reports").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("FY2025-Reports").path))
    }

    func testDuplicateStructureMultipleYears() async throws {
        // Create folders with multiple occurrences of year
        let folder1 = sourceDir.appendingPathComponent("2025-Q1")
        let folder2 = folder1.appendingPathComponent("Reports-2025")
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)

        let destination = tempDir.appendingPathComponent("Dest")

        _ = try await FileOperationQueue.shared.duplicateStructure(
            source: sourceDir,
            destination: destination,
            yearSubstitution: ("2025", "2026")
        )

        // Both occurrences should be substituted
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("2026-Q1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("2026-Q1/Reports-2026").path))
    }

    // MARK: - Error Handling Tests

    func testDuplicateStructureDestinationExists() async throws {
        let destination = tempDir.appendingPathComponent("ExistingDest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            _ = try await FileOperationQueue.shared.duplicateStructure(
                source: sourceDir,
                destination: destination,
                yearSubstitution: nil
            )
            XCTFail("Expected destinationExists error")
        } catch let error as FileOperationError {
            if case .destinationExists = error {
                // Expected
            } else {
                XCTFail("Expected destinationExists error, got \(error)")
            }
        }
    }

    // MARK: - Year Detection Tests

    func testYearDetectionFindsYear() {
        let model = DuplicateStructureModel(sourceURL: URL(fileURLWithPath: "/test/FY2025-Reports"))

        XCTAssertEqual(model.fromYear, "2025")
        XCTAssertEqual(model.toYear, "2026")
        XCTAssertTrue(model.substituteYears)
    }

    func testYearDetectionNoYear() {
        let model = DuplicateStructureModel(sourceURL: URL(fileURLWithPath: "/test/Reports-Final"))

        XCTAssertEqual(model.fromYear, "")
        XCTAssertEqual(model.toYear, "")
        XCTAssertFalse(model.substituteYears)
    }
}
