import XCTest
@testable import detours_server

final class ServerArchiveOperationsTests: XCTestCase {
    func testCreateZipArchivePreservesSourcesAndReportsProgress() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "hello.txt", content: "Hello")
        let operations = ArchiveOperations()
        var frames: [ArchiveProgressFrame] = []

        let archivePath = try operations.createArchive(
            items: [source.path],
            format: "zip",
            archiveName: "bundle",
            password: nil
        ) { frame in
            frames.append(frame)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath))
        XCTAssertEqual(URL(fileURLWithPath: archivePath).lastPathComponent, "bundle.zip")
        XCTAssertEqual(frames.first?.phase, .starting)
        XCTAssertEqual(frames.last?.phase, .completed)
    }

    func testExtractZipArchiveMaterialisesSingleTopLevelItem() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "hello.txt", content: "Hello")
        let operations = ArchiveOperations()
        let archivePath = try operations.createArchive(
            items: [source.path],
            format: "zip",
            archiveName: "bundle",
            password: nil
        )
        try FileManager.default.removeItem(at: source)

        let extractedPath = try operations.extractArchive(archive: archivePath, password: nil)

        XCTAssertEqual(URL(fileURLWithPath: extractedPath).lastPathComponent, "hello.txt")
        XCTAssertEqual(try String(contentsOfFile: extractedPath, encoding: .utf8), "Hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath))
    }

    func testExtractZipArchiveWrapsMultipleTopLevelItems() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let first = try createTestFile(in: temp, name: "a.txt", content: "A")
        let second = try createTestFile(in: temp, name: "b.txt", content: "B")
        let operations = ArchiveOperations()
        let archivePath = try operations.createArchive(
            items: [first.path, second.path],
            format: "zip",
            archiveName: "bundle",
            password: nil
        )
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)

        let extractedPath = try operations.extractArchive(archive: archivePath, password: nil)
        let extractedURL = URL(fileURLWithPath: extractedPath)

        XCTAssertEqual(extractedURL.lastPathComponent, "bundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.appendingPathComponent("b.txt").path))
    }

    func testMissingToolNamesToolAndLeavesSourcesUnchanged() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "hello.txt", content: "Hello")
        let operations = ArchiveOperations(resolveTool: { _ in nil })

        XCTAssertThrowsError(
            try operations.createArchive(items: [source.path], format: "zip", archiveName: "bundle", password: nil)
        ) { error in
            XCTAssertEqual(error as? ArchiveOperationsError, .missingTool("zip"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("bundle.zip").path))
    }

    func testMissing7zToolSurfacesErrorAndLeavesSourcesUnchanged() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "hello.txt", content: "Hello")
        let operations = ArchiveOperations(resolveTool: { tool in tool == "7z" ? nil : "/usr/bin/\(tool)" })

        XCTAssertThrowsError(
            try operations.createArchive(items: [source.path], format: "sevenZ", archiveName: "bundle", password: nil)
        ) { error in
            XCTAssertEqual(error as? ArchiveOperationsError, .missingTool("7z"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("bundle.7z").path))
    }

    func testProcessFailureLeavesSourcesUnchangedAndRemovesPartialArchive() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "hello.txt", content: "Hello")
        let operations = ArchiveOperations(
            resolveTool: { _ in "/usr/bin/false" },
            runProcess: { _, _, _ in ServerProcessResult(status: 1, stderr: "zip failed") }
        )

        XCTAssertThrowsError(
            try operations.createArchive(items: [source.path], format: "zip", archiveName: "bundle", password: nil)
        ) { error in
            XCTAssertEqual(error as? ArchiveOperationsError, .processFailed("zip failed"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("bundle.zip").path))
    }

    func testPasswordArchiveCreationIsRejectedBeforeProcessLaunch() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "hello.txt", content: "Hello")
        let didRunProcess = LockedBox(false)
        let operations = ArchiveOperations(
            runProcess: { _, _, _ in
                didRunProcess.value = true
                return ServerProcessResult(status: 0, stderr: "")
            }
        )

        XCTAssertThrowsError(
            try operations.createArchive(items: [source.path], format: "zip", archiveName: "bundle", password: "secret")
        ) { error in
            XCTAssertEqual(error as? ArchiveOperationsError, .passwordUnsupported)
        }
        XCTAssertFalse(didRunProcess.value)
    }

    func testTarCreateUsesOptionDelimiterBeforeItemNames() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "-leading-dash.txt", content: "Hello")
        let capturedArguments = LockedBox<[String]>([])
        let operations = ArchiveOperations(
            resolveTool: { _ in "/usr/bin/tar" },
            runProcess: { _, arguments, _ in
                capturedArguments.value = arguments
                return ServerProcessResult(status: 0, stderr: "")
            }
        )

        _ = try operations.createArchive(items: [source.path], format: "tarGz", archiveName: "bundle", password: nil)

        XCTAssertEqual(capturedArguments.value.dropFirst(2).first, "--")
        XCTAssertEqual(capturedArguments.value.last, "-leading-dash.txt")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
