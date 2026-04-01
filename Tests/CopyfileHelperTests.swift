import XCTest
@testable import Detours

final class CopyfileHelperTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CopyfileHelperTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testCopyFilePreservesMetadata() throws {
        // Create source file with specific permissions and xattrs
        let source = tempDir.appendingPathComponent("source.txt")
        let destination = tempDir.appendingPathComponent("dest.txt")
        let content = "Hello, World!"
        try content.write(to: source, atomically: true, encoding: .utf8)

        // Set a specific modification date
        let targetDate = Date(timeIntervalSince1970: 1_000_000_000) // 2001-09-09
        try FileManager.default.setAttributes([.modificationDate: targetDate], ofItemAtPath: source.path)

        // Set extended attribute
        let xattrData = Data("test-value".utf8)
        _ = source.path.withCString { path in
            xattrData.withUnsafeBytes { bytes in
                setxattr(path, "com.test.attribute", bytes.baseAddress, bytes.count, 0, 0)
            }
        }

        try CopyfileHelper.copy(from: source, to: destination)

        // Verify content
        let copiedContent = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(copiedContent, content, "Content should match")

        // Verify modification date is preserved
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let modDate = attrs[.modificationDate] as? Date
        XCTAssertNotNil(modDate)
        if let modDate {
            XCTAssertEqual(modDate.timeIntervalSince1970, targetDate.timeIntervalSince1970, accuracy: 1.0, "Modification date should be preserved")
        }

        // Verify xattr is preserved
        var buffer = [UInt8](repeating: 0, count: 256)
        let xattrSize = destination.path.withCString { path in
            getxattr(path, "com.test.attribute", &buffer, buffer.count, 0, 0)
        }
        XCTAssertGreaterThan(xattrSize, 0, "Extended attribute should be preserved")
        if xattrSize > 0 {
            let xattrValue = String(bytes: buffer[..<xattrSize], encoding: .utf8)
            XCTAssertEqual(xattrValue, "test-value", "Extended attribute value should match")
        }
    }

    func testCopyFileProgressCallback() throws {
        // Create a file with known size
        let source = tempDir.appendingPathComponent("progress_source.bin")
        let destination = tempDir.appendingPathComponent("progress_dest.bin")
        let size = 1_000_000 // 1 MB
        let data = Data(count: size)
        try data.write(to: source)

        let collector = ByteCollector()

        try CopyfileHelper.copy(from: source, to: destination) { bytesCopied in
            collector.append(bytesCopied)
            return true
        }

        let reportedBytes = collector.values

        // Should have received at least one progress callback
        XCTAssertFalse(reportedBytes.isEmpty, "Should receive progress callbacks")

        // Last reported bytes should equal total size
        if let lastBytes = reportedBytes.last {
            XCTAssertEqual(lastBytes, Int64(size), "Final bytes should equal file size")
        }

        // Bytes should be monotonically increasing
        for i in 1..<reportedBytes.count {
            XCTAssertGreaterThanOrEqual(reportedBytes[i], reportedBytes[i - 1], "Bytes should increase monotonically")
        }
    }

    func testCopyFileCancellation() throws {
        // Create a file
        let source = tempDir.appendingPathComponent("cancel_source.bin")
        let destination = tempDir.appendingPathComponent("cancel_dest.bin")
        let data = Data(count: 2_000_000) // 2 MB
        try data.write(to: source)

        // Cancel immediately in the progress callback
        do {
            try CopyfileHelper.copy(from: source, to: destination) { _ in
                return false // Cancel
            }
            XCTFail("Should have thrown cancellation error")
        } catch let error as FileOperationError {
            if case .cancelled = error {
                // Expected
            } else {
                XCTFail("Expected cancellation error, got \(error)")
            }
        }

        // Partial file should be cleaned up
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Partial file should be cleaned up on cancel")
    }

    func testCopyFileLargeBuffer() throws {
        // Verify that copy succeeds with a larger file (exercising the 1 MB buffer)
        let source = tempDir.appendingPathComponent("large_source.bin")
        let destination = tempDir.appendingPathComponent("large_dest.bin")
        let size = 5_000_000 // 5 MB
        let data = Data(repeating: 0xAB, count: size)
        try data.write(to: source)

        try CopyfileHelper.copy(from: source, to: destination)

        let copiedData = try Data(contentsOf: destination)
        XCTAssertEqual(copiedData.count, size, "Copied file should have same size")
        XCTAssertEqual(copiedData[0], 0xAB, "Copied file should have same content")
        XCTAssertEqual(copiedData[size - 1], 0xAB, "Copied file should have same content at end")
    }

    func testCopyFileDirectory() throws {
        // Create a directory with nested structure
        let sourceDir = tempDir.appendingPathComponent("source_dir")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        // Create files in the directory
        try "file1".write(to: sourceDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        let subDir = sourceDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "file2".write(to: subDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let destDir = tempDir.appendingPathComponent("dest_dir")

        try CopyfileHelper.copy(from: sourceDir, to: destDir)

        // Verify structure
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.path), "Destination directory should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("file1.txt").path), "file1.txt should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("sub/file2.txt").path), "sub/file2.txt should exist")

        // Verify content
        let content1 = try String(contentsOf: destDir.appendingPathComponent("file1.txt"), encoding: .utf8)
        XCTAssertEqual(content1, "file1", "file1 content should match")
        let content2 = try String(contentsOf: destDir.appendingPathComponent("sub/file2.txt"), encoding: .utf8)
        XCTAssertEqual(content2, "file2", "file2 content should match")
    }
}

/// Thread-safe collector for progress callback bytes
private final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int64] = []

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ value: Int64) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}
