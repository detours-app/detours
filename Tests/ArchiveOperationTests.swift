import DetoursProcess
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

    func testCreateAndExtractEncryptedZipRoundTrips() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "secret.txt", content: "classified payload")

        let archive = try await FileOperationQueue.shared.archive(
            items: [source],
            format: .zip,
            archiveName: "encrypted",
            password: "correct horse"
        )
        try FileManager.default.removeItem(at: source)
        let extracted = try await FileOperationQueue.shared.extract(
            archive: archive,
            password: "correct horse"
        )

        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "classified payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testEncryptedZipWrongPasswordRetriesWithoutPartialOutput() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let publicFile = try createTestFile(in: temp, name: "public.txt", content: "public")
        let secretFile = try createTestFile(in: temp, name: "secret.txt", content: "secret")
        let archive = temp.appendingPathComponent("mixed.zip")

        try runProcess(
            executable: CompressionTool.zip.path,
            arguments: ["-q", archive.path, publicFile.lastPathComponent],
            currentDirectory: temp
        )
        let appendResult = try await PtyProcessRunner().run(PtyProcessInvocation(
            executable: CompressionTool.zip.path,
            arguments: ["-e", "-q", archive.path, secretFile.lastPathComponent],
            currentDirectory: temp,
            password: "right-password",
            responses: [.password, .password]
        ))
        XCTAssertEqual(appendResult.status, 0, appendResult.outputString)
        try FileManager.default.removeItem(at: publicFile)
        try FileManager.default.removeItem(at: secretFile)

        do {
            _ = try await FileOperationQueue.shared.extract(archive: archive, password: "wrong-password")
            XCTFail("Expected a password retry")
        } catch FileOperationError.archivePasswordRequired {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: publicFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretFile.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temp.path).contains {
            $0.hasPrefix(".detours-extract-")
        })
        XCTAssertTrue(FileOperationQueue.isZipPasswordFailure("incorrect password", status: 1))
        XCTAssertTrue(FileOperationQueue.isZipPasswordFailure("password incorrect--reenter:", status: 1))
        XCTAssertTrue(FileOperationQueue.isZipPasswordFailure("", status: 82))
        XCTAssertFalse(FileOperationQueue.isZipPasswordFailure("central directory corrupt", status: 1))
    }

    func testCreateListAndExtractEncrypted7zRoundTrips() async throws {
        guard CompressionTools.isAvailable(.sevenZip) else { throw XCTSkip("7z is unavailable") }
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let payload = Data(repeating: 0x5A, count: 2 * 1_024 * 1_024)
        let source = temp.appendingPathComponent("payload.bin")
        try payload.write(to: source)
        var progressUpdates = 0
        FileOperationQueue.shared.onProgressUpdate = { progress in
            if progress.bytesTotal > 0 { progressUpdates += 1 }
        }
        defer { FileOperationQueue.shared.onProgressUpdate = nil }

        let archive = try await FileOperationQueue.shared.archive(
            items: [source],
            format: .sevenZ,
            archiveName: "encrypted",
            password: "seven-secret"
        )
        try FileManager.default.removeItem(at: source)
        let extracted = try await FileOperationQueue.shared.extract(
            archive: archive,
            password: "seven-secret"
        )

        XCTAssertEqual(try Data(contentsOf: extracted), payload)
        XCTAssertGreaterThan(progressUpdates, 0)
    }

    func testEncrypted7zWrongPasswordDiffersFromCorruption() async throws {
        guard CompressionTools.isAvailable(.sevenZip) else { throw XCTSkip("7z is unavailable") }
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "secret.txt", content: "seven secret")
        let archive = try await FileOperationQueue.shared.archive(
            items: [source],
            format: .sevenZ,
            archiveName: "protected",
            password: "right-password"
        )
        try FileManager.default.removeItem(at: source)

        do {
            _ = try await FileOperationQueue.shared.extract(archive: archive, password: "wrong-password")
            XCTFail("Expected password retry")
        } catch FileOperationError.archivePasswordRequired {}

        let corrupt = temp.appendingPathComponent("corrupt.7z")
        try Data("not an archive".utf8).write(to: corrupt)
        do {
            _ = try await FileOperationQueue.shared.extract(archive: corrupt, password: "any-password")
            XCTFail("Expected corruption failure")
        } catch let FileOperationError.archiveExtractionFailed(message) {
            XCTAssertFalse(message.lowercased().contains("wrong password"))
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temp.path).contains {
            $0.hasPrefix(".detours-extract-")
        })
    }

    func testEncryptedAESZipPromptsAndRoundTripsThroughSevenZip() async throws {
        guard CompressionTools.isAvailable(.sevenZip) else { throw XCTSkip("7z is unavailable") }
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "aes-secret.txt", content: "AES secret")
        let archive = temp.appendingPathComponent("aes-encrypted.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)
        process.arguments = [
            "a", "-bd", "-y", "-tzip", "-mem=AES256", "-pright-password",
            archive.path, source.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.removeItem(at: source)

        let metadata = try XCTUnwrap(ZipArchiveMetadata.read(from: archive))
        XCTAssertTrue(metadata.isEncrypted)
        XCTAssertTrue(metadata.requiresSevenZip)

        do {
            _ = try await FileOperationQueue.shared.extract(archive: archive)
            XCTFail("Expected the encrypted ZIP to request a password")
        } catch FileOperationError.archivePasswordRequired {}

        do {
            _ = try await FileOperationQueue.shared.extract(archive: archive, password: "wrong-password")
            XCTFail("Expected an incorrect password retry")
        } catch FileOperationError.archivePasswordRequired {}

        let extracted = try await FileOperationQueue.shared.extract(
            archive: archive,
            password: "right-password"
        )
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "AES secret")
    }

    func testExtractionFailurePresentationNamesExtraction() {
        let presentation = FileOperationQueue.errorPresentation(
            for: FileOperationError.archiveExtractionFailed("unsupported compression")
        )

        XCTAssertEqual(presentation.title, "The archive couldn't be extracted.")
        XCTAssertEqual(presentation.body, "unsupported compression")
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

        // Create a file, archive it, then delete the original
        try createTestFile(in: temp, name: "readme.txt", content: "Read me")
        let file = temp.appendingPathComponent("readme.txt")
        let archive = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "readme",
            password: nil
        )
        try FileManager.default.removeItem(at: file)

        // Extract — should put readme.txt directly in temp/
        let extracted = try await FileOperationQueue.shared.extract(archive: archive)

        // The single new item should be readme.txt
        XCTAssertEqual(extracted.lastPathComponent, "readme.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))

        let content = try String(contentsOf: extracted, encoding: .utf8)
        XCTAssertEqual(content, "Read me")
    }

    func testExtractTarGzArchive() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create a folder, archive it, then delete the original
        let folder = try createTestFolder(in: temp, name: "project")
        try createTestFile(in: folder, name: "main.swift", content: "import Foundation")

        let archive = try await FileOperationQueue.shared.archive(
            items: [folder],
            format: .tarGz,
            archiveName: "project",
            password: nil
        )
        try FileManager.default.removeItem(at: folder)

        // Extract — should recreate project/ directly in temp/
        let extracted = try await FileOperationQueue.shared.extract(archive: archive)

        XCTAssertEqual(extracted.lastPathComponent, "project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))

        let extractedFile = extracted.appendingPathComponent("main.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFile.path))
    }

    func testExtractTarRejectsParentTraversalMember() async throws {
        let temp = try createTempDirectory()
        let escapedName = "detours-archive-escape-\(UUID().uuidString).txt"
        let escaped = temp.deletingLastPathComponent().appendingPathComponent(escapedName)
        defer {
            cleanupTempDirectory(temp)
            try? FileManager.default.removeItem(at: escaped)
        }
        try Data("sentinel".utf8).write(to: escaped)
        let source = try createTestFolder(in: temp, name: "source")
        _ = try createTestFile(in: source, name: "payload.txt", content: "escape")
        let archive = temp.appendingPathComponent("malicious.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.tar.path)
        process.arguments = [
            "-czf", archive.path,
            "-s", ",payload.txt,../\(escapedName),",
            "-C", source.path,
            "payload.txt",
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        do {
            _ = try await FileOperationQueue.shared.extract(archive: archive)
            XCTFail("Expected parent-traversal member to be rejected")
        } catch let error as FileOperationError {
            guard case let .archiveExtractionFailed(message) = error else {
                return XCTFail("Expected archiveExtractionFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("unsafe path"))
        }
        XCTAssertEqual(try String(contentsOf: escaped, encoding: .utf8), "sentinel")
    }

    func testExtractKeepsBothOnConflict() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create a file and archive it
        try createTestFile(in: temp, name: "data.txt", content: "Archived content")
        let file = temp.appendingPathComponent("data.txt")
        let archive = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "data",
            password: nil
        )

        // Overwrite original with different content
        try Data("Existing content".utf8).write(to: file)

        // Extract — conflict resolved as Keep Both (test default)
        let extracted = try await FileOperationQueue.shared.extract(archive: archive)

        // Original should remain untouched
        let originalContent = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(originalContent, "Existing content")

        // Extracted version should have " copy" suffix
        XCTAssertEqual(extracted.lastPathComponent, "data copy.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))

        let extractedContent = try String(contentsOf: extracted, encoding: .utf8)
        XCTAssertEqual(extractedContent, "Archived content")
    }

    func testExtractReplaceUndoRestoresDisplacedOriginal() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let file = try createTestFile(in: temp, name: "data.txt", content: "archived")
        let archive = try await FileOperationQueue.shared.archive(
            items: [file],
            format: .zip,
            archiveName: "data",
            password: nil
        )
        try Data("original".utf8).write(to: file)

        let queue = FileOperationQueue.shared
        let undoManager = UndoManager()
        queue.conflictChoiceOverrideForTesting = .replace
        defer { queue.conflictChoiceOverrideForTesting = nil }
        let extracted = try await queue.extract(archive: archive, undoManager: undoManager)

        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "archived")
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
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

    func testSupportsPasswordFlags() {
        XCTAssertTrue(ArchiveFormat.zip.supportsPassword)
        XCTAssertTrue(ArchiveFormat.sevenZ.supportsPassword)
        XCTAssertFalse(ArchiveFormat.tarGz.supportsPassword)
        XCTAssertFalse(ArchiveFormat.tarBz2.supportsPassword)
        XCTAssertFalse(ArchiveFormat.tarXz.supportsPassword)
    }

    private func runProcess(executable: String, arguments: [String], currentDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
    }
}
