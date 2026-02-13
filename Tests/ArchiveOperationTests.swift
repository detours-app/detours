import XCTest
@testable import Detours

@MainActor
final class ArchiveOperationTests: XCTestCase {

    // MARK: - Format Detection

    func testDetectZipFormat() {
        let url = URL(fileURLWithPath: "/tmp/test.zip")
        XCTAssertEqual(ArchiveFormat.detect(from: url), .zip)
    }

    func testDetect7zFormat() {
        let url = URL(fileURLWithPath: "/tmp/test.7z")
        XCTAssertEqual(ArchiveFormat.detect(from: url), .sevenZ)
    }

    func testDetectTarGzFormat() {
        let url = URL(fileURLWithPath: "/tmp/test.tar.gz")
        XCTAssertEqual(ArchiveFormat.detect(from: url), .tarGz)
    }

    func testDetectTgzFormat() {
        let url = URL(fileURLWithPath: "/tmp/test.tgz")
        XCTAssertEqual(ArchiveFormat.detect(from: url), .tarGz)
    }

    func testDetectTarBz2Format() {
        let url = URL(fileURLWithPath: "/tmp/test.tar.bz2")
        XCTAssertEqual(ArchiveFormat.detect(from: url), .tarBz2)
    }

    func testDetectTarXzFormat() {
        let url = URL(fileURLWithPath: "/tmp/test.tar.xz")
        XCTAssertEqual(ArchiveFormat.detect(from: url), .tarXz)
    }

    func testDetectUnknownFormat() {
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        XCTAssertNil(ArchiveFormat.detect(from: url))
    }

    func testDetectCaseInsensitive() {
        let url = URL(fileURLWithPath: "/tmp/test.ZIP")
        XCTAssertEqual(ArchiveFormat.detect(from: url), .zip)
    }

    // MARK: - Tool Detection

    func testDetectZipAvailable() {
        XCTAssertTrue(CompressionTools.isAvailable(.zip), "zip should be available at /usr/bin/zip")
    }

    func testDetectUnzipAvailable() {
        XCTAssertTrue(CompressionTools.isAvailable(.unzip), "unzip should be available at /usr/bin/unzip")
    }

    func testDetectTarAvailable() {
        XCTAssertTrue(CompressionTools.isAvailable(.tar), "tar should be available at /usr/bin/tar")
    }

    func testIsExtractableForArchive() {
        let url = URL(fileURLWithPath: "/tmp/test.zip")
        XCTAssertTrue(CompressionTools.isExtractable(url))
    }

    func testIsExtractableForNonArchive() {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        XCTAssertFalse(CompressionTools.isExtractable(url))
    }

    // MARK: - Archive Creation

    func testCreateZipArchive() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        try createTestFile(in: temp, name: "hello.txt", content: "Hello World")

        let file = temp.appendingPathComponent("hello.txt")
        let result = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "hello",
            password: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "hello.zip")

        let size = try FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 0, "Archive should not be empty")
    }

    func testCreateZipArchiveMultipleFiles() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file1 = try createTestFile(in: temp, name: "a.txt", content: "File A")
        let file2 = try createTestFile(in: temp, name: "b.txt", content: "File B")

        let result = try await FileOperationQueue.shared.archive(
            items: [file1, file2],
            format: .zip,
            archiveName: "bundle",
            password: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "bundle.zip")
    }

    func testCreateZipWithPassword() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        try createTestFile(in: temp, name: "secret.txt", content: "Secret data")
        let file = temp.appendingPathComponent("secret.txt")

        let result = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "encrypted",
            password: "testpass123"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "encrypted.zip")
    }

    func testCreateTarGzArchive() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "data")
        try createTestFile(in: folder, name: "info.txt", content: "Some info")

        let result = try await FileOperationQueue.shared.archive(
            items: [folder],
            format: .tarGz,
            archiveName: "data",
            password: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "data.tar.gz")
    }

    func testCreateTarBz2Archive() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        try createTestFile(in: temp, name: "doc.txt", content: "Document")
        let file = temp.appendingPathComponent("doc.txt")

        let result = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .tarBz2,
            archiveName: "doc",
            password: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "doc.tar.bz2")
    }

    func testArchiveNameCollision() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        try createTestFile(in: temp, name: "file.txt", content: "Content")
        let file = temp.appendingPathComponent("file.txt")

        // Create first archive
        let first = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "file",
            password: nil
        )
        XCTAssertEqual(first.lastPathComponent, "file.zip")

        // Create second — should get " 2" suffix
        let second = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "file",
            password: nil
        )
        XCTAssertEqual(second.lastPathComponent, "file 2.zip")
    }

    // MARK: - Extraction

    func testExtractZipArchive() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create a zip first
        try createTestFile(in: temp, name: "readme.txt", content: "Read me")
        let file = temp.appendingPathComponent("readme.txt")
        let archive = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "readme",
            password: nil
        )

        // Extract it
        let extracted = try await FileOperationQueue.shared.extract(archive: archive)

        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
        XCTAssertEqual(extracted.lastPathComponent, "readme")

        let extractedFile = extracted.appendingPathComponent("readme.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFile.path))

        let content = try String(contentsOf: extractedFile, encoding: .utf8)
        XCTAssertEqual(content, "Read me")
    }

    func testExtractTarGzArchive() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create a tar.gz first
        let folder = try createTestFolder(in: temp, name: "project")
        try createTestFile(in: folder, name: "main.swift", content: "import Foundation")

        let archive = try await FileOperationQueue.shared.archive(
            items: [folder],
            format: .tarGz,
            archiveName: "project",
            password: nil
        )

        // Extract it
        let extracted = try await FileOperationQueue.shared.extract(archive: archive)

        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
        XCTAssertEqual(extracted.lastPathComponent, "project 2") // "project" folder already exists

        let extractedFile = extracted.appendingPathComponent("project/main.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFile.path))
    }

    func testExtractPasswordZip() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create encrypted zip
        try createTestFile(in: temp, name: "private.txt", content: "Top secret")
        let file = temp.appendingPathComponent("private.txt")
        let archive = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "private",
            password: "mypass"
        )

        // Extract with correct password
        let extracted = try await FileOperationQueue.shared.extract(archive: archive, password: "mypass")

        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
        let extractedFile = extracted.appendingPathComponent("private.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFile.path))

        let content = try String(contentsOf: extractedFile, encoding: .utf8)
        XCTAssertEqual(content, "Top secret")
    }

    func testExtractDestinationCollision() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        try createTestFile(in: temp, name: "data.txt", content: "Data")
        let file = temp.appendingPathComponent("data.txt")
        let archive = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "data",
            password: nil
        )

        // Extract once
        let first = try await FileOperationQueue.shared.extract(archive: archive)
        XCTAssertEqual(first.lastPathComponent, "data")

        // Extract again — should get " 2" suffix
        let second = try await FileOperationQueue.shared.extract(archive: archive)
        XCTAssertEqual(second.lastPathComponent, "data 2")
    }

    // MARK: - Dialog Model

    func testDialogDefaultNameSingleFile() {
        let url = URL(fileURLWithPath: "/tmp/document.pdf")
        let model = ArchiveModel(sourceURLs: [url])
        XCTAssertEqual(model.archiveName, "document")
    }

    func testDialogDefaultNameSingleFolder() {
        let url = URL(fileURLWithPath: "/tmp/Photos/", isDirectory: true)
        let model = ArchiveModel(sourceURLs: [url])
        XCTAssertEqual(model.archiveName, "Photos")
    }

    func testDialogDefaultNameMultiple() {
        let urls = [
            URL(fileURLWithPath: "/tmp/Projects/a.txt"),
            URL(fileURLWithPath: "/tmp/Projects/b.txt"),
        ]
        let model = ArchiveModel(sourceURLs: urls)
        XCTAssertEqual(model.archiveName, "Projects")
    }

    func testDialogValidation() {
        let url = URL(fileURLWithPath: "/tmp/file.txt")
        let model = ArchiveModel(sourceURLs: [url])

        model.archiveName = "valid-name"
        XCTAssertTrue(model.isValid)
        XCTAssertNil(model.validationError)

        model.archiveName = ""
        XCTAssertFalse(model.isValid)
        XCTAssertNotNil(model.validationError)

        model.archiveName = "bad/name"
        XCTAssertFalse(model.isValid)
        XCTAssertNotNil(model.validationError)
    }

    func testPasswordDisabledForTarFormats() {
        XCTAssertFalse(ArchiveFormat.tarGz.supportsPassword)
        XCTAssertFalse(ArchiveFormat.tarBz2.supportsPassword)
        XCTAssertFalse(ArchiveFormat.tarXz.supportsPassword)
    }

    func testPasswordEnabledForZipAnd7z() {
        XCTAssertTrue(ArchiveFormat.zip.supportsPassword)
        XCTAssertTrue(ArchiveFormat.sevenZ.supportsPassword)
    }
}
