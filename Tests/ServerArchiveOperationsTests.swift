import DetoursProcess
import XCTest
@testable import detours_server

final class ServerArchiveOperationsTests: XCTestCase {
    func testEncryptedZipRoundTripsThroughPtyRunner() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "secret.txt", content: "helper secret")
        let operations = ArchiveOperations()

        let archivePath = try operations.createArchive(
            items: [source.path],
            format: "zip",
            archiveName: "encrypted",
            password: "helper-password"
        )
        try FileManager.default.removeItem(at: source)
        let extractedPath = try operations.extractArchive(
            archive: archivePath,
            password: "helper-password"
        )

        XCTAssertEqual(try String(contentsOfFile: extractedPath, encoding: .utf8), "helper secret")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath))
    }

    func testEncryptedSevenZRoundTripsThroughPtyRunner() throws {
        guard executableOnPath("7z") != nil else { throw XCTSkip("7z is unavailable") }
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "secret.txt", content: "helper seven secret")
        let operations = ArchiveOperations()

        let archivePath = try operations.createArchive(
            items: [source.path],
            format: "sevenZ",
            archiveName: "encrypted",
            password: "helper-password"
        )
        try FileManager.default.removeItem(at: source)
        let extractedPath = try operations.extractArchive(
            archive: archivePath,
            password: "helper-password"
        )

        XCTAssertEqual(try String(contentsOfFile: extractedPath, encoding: .utf8), "helper seven secret")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath))
    }

    func testWrongPasswordMapsToRetryAndCleansTemporaryOutput() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "secret.txt", content: "helper secret")
        let operations = ArchiveOperations()
        let archivePath = try operations.createArchive(
            items: [source.path],
            format: "zip",
            archiveName: "encrypted",
            password: "right-password"
        )
        try FileManager.default.removeItem(at: source)

        XCTAssertThrowsError(try operations.extractArchive(archive: archivePath, password: "wrong-password")) {
            XCTAssertEqual($0 as? ArchiveOperationsError, .wrongPassword)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temp.path).contains {
            $0.hasPrefix(".detours-extract-")
        })
    }

    func testZipPasswordByteLimit() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "secret.txt", content: "helper secret")
        let zipArchive = temp.appendingPathComponent("input.zip")
        try Data("placeholder".utf8).write(to: zipArchive)
        let ptyInvocations = LockedBox<[PtyProcessInvocation]>([])
        let toolResolutions = LockedBox(0)
        let operations = ArchiveOperations(
            resolveTool: { tool in
                toolResolutions.value += 1
                return "/usr/bin/\(tool)"
            },
            runPtyProcess: { invocation in
                ptyInvocations.value.append(invocation)
                return PtyProcessResult(status: 0, output: Data())
            }
        )
        let eightyBytes = String(repeating: "a", count: 80)
        let multibyteEightyOneBytes = String(repeating: "a", count: 79) + "é"

        _ = try operations.createArchive(
            items: [source.path],
            format: "zip",
            archiveName: "accepted",
            password: eightyBytes
        )
        XCTAssertThrowsError(
            try operations.createArchive(
                items: [source.path],
                format: "zip",
                archiveName: "rejected",
                password: multibyteEightyOneBytes
            )
        ) {
            XCTAssertEqual(
                $0 as? ArchiveOperationsError,
                .invalidPassword("ZIP passwords are limited to 80 UTF-8 bytes")
            )
        }
        XCTAssertThrowsError(
            try operations.extractArchive(archive: zipArchive.path, password: String(repeating: "b", count: 81))
        ) {
            XCTAssertEqual(
                $0 as? ArchiveOperationsError,
                .invalidPassword("ZIP passwords are limited to 80 UTF-8 bytes")
            )
        }
        _ = try operations.createArchive(
            items: [source.path],
            format: "sevenZ",
            archiveName: "unlimited",
            password: String(repeating: "c", count: 200)
        )

        XCTAssertEqual(ptyInvocations.value.count, 2)
        XCTAssertEqual(toolResolutions.value, 2)
    }

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

    func testPasswordArchiveCreationUsesPtyRunnerWithoutProcessArguments() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "hello.txt", content: "Hello")
        let didRunProcess = LockedBox(false)
        let invocation = LockedBox<PtyProcessInvocation?>(nil)
        let operations = ArchiveOperations(
            runProcess: { _, _, _ in
                didRunProcess.value = true
                return ServerProcessResult(status: 0, stderr: "")
            },
            runPtyProcess: { captured in
                invocation.value = captured
                return PtyProcessResult(status: 1, output: Data("expected failure".utf8))
            }
        )

        XCTAssertThrowsError(
            try operations.createArchive(items: [source.path], format: "zip", archiveName: "bundle", password: "secret")
        ) { error in
            XCTAssertEqual(error as? ArchiveOperationsError, .processFailed("expected failure"))
        }
        XCTAssertFalse(didRunProcess.value)
        XCTAssertEqual(invocation.value?.executable, "/usr/bin/zip")
        XCTAssertEqual(invocation.value?.password, "secret")
        XCTAssertFalse(invocation.value?.arguments.contains(where: { $0.contains("secret") }) ?? true)
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

    func testZipCreateUsesSafeOptionBoundaryAndCommonAncestorLayout() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let alpha = try createTestFolder(in: temp, name: "Alpha")
        let beta = try createTestFolder(in: temp, name: "Beta")
        let first = try createTestFile(in: alpha, name: "-TT", content: "one")
        let second = try createTestFile(in: beta, name: "two.txt", content: "two")
        let capturedArguments = LockedBox<[String]>([])
        let capturedDirectory = LockedBox<URL?>(nil)
        let operations = ArchiveOperations(
            resolveTool: { _ in "/usr/bin/zip" },
            runProcess: { _, arguments, directory in
                capturedArguments.value = arguments
                capturedDirectory.value = directory
                return ServerProcessResult(status: 0, stderr: "")
            }
        )

        _ = try operations.createArchive(
            items: [first.path, second.path],
            format: "zip",
            archiveName: "bundle",
            password: nil
        )

        XCTAssertEqual(capturedDirectory.value?.standardizedFileURL, temp.standardizedFileURL)
        XCTAssertTrue(capturedArguments.value.contains("-nw"))
        let delimiter = try XCTUnwrap(capturedArguments.value.firstIndex(of: "--"))
        XCTAssertEqual(Array(capturedArguments.value.suffix(from: delimiter + 1)), ["Alpha/-TT", "Beta/two.txt"])
    }
}

private func executableOnPath(_ name: String) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", name]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
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

#if os(Linux)
private func createTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func createTestFile(in directory: URL, name: String, content: String = "test") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
    return url
}

private func cleanupTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
#endif
