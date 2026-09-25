import XCTest
@testable import detours_server

final class TransferModeTests: XCTestCase {
    func testNegativeUploadByteCountDoesNotReplaceDestination() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let destination = try createTestFile(in: temp, name: "destination.bin", content: "original")
        let partial = temp.appendingPathComponent("destination.bin.detours-partial")
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt8(1)
        writer.writeData(Data("/unused-source".utf8))
        writer.writeData(Data(destination.path.utf8))
        writer.writeInt64(-1)
        var frameLength = UInt32(writer.data.count).bigEndian
        let framePrefix = Data(bytes: &frameLength, count: MemoryLayout<UInt32>.size)
        inputPipe.fileHandleForWriting.write(framePrefix + writer.data)
        try inputPipe.fileHandleForWriting.close()

        XCTAssertThrowsError(
            try TransferMode(
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            ).run()
        ) { error in
            XCTAssertEqual(error as? TransferModeError, .invalidHandshake)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testLegacyUploadRefusesBeforeTouchingDestinationOrPartialSentinel() throws {
        for count in [Int64(0), 3, 200_000] {
            let home = try createTempDirectory()
            defer { cleanupTempDirectory(home) }
            let destination = try createTestFile(in: home, name: "destination.bin", content: "original")
            let partial = try createTestFile(in: home, name: "destination.bin.detours-partial", content: "another operation")
            let input = Pipe()
            let output = Pipe()
            input.fileHandleForWriting.write(legacyFrame(direction: 1, source: "/unused", destination: destination.path, count: count))
            try input.fileHandleForWriting.close()
            XCTAssertThrowsError(try TransferMode(input: input.fileHandleForReading, output: output.fileHandleForWriting).run()) {
                XCTAssertEqual($0 as? ServerRPCError, .acceptedOperationRequired)
            }
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
            XCTAssertEqual(try String(contentsOf: partial, encoding: .utf8), "another operation")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path).sorted(),
                           ["destination.bin", "destination.bin.detours-partial"])
        }
    }

    func testLegacyUploadRefusesBeforeCreatingMissingDestinationParents() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let input = Pipe()
        let output = Pipe()
        input.fileHandleForWriting.write(legacyFrame(direction: 1, source: "/unused", destination: home.appendingPathComponent("missing/file").path, count: 3))
        try input.fileHandleForWriting.close()
        XCTAssertThrowsError(try TransferMode(input: input.fileHandleForReading, output: output.fileHandleForWriting).run()) {
            XCTAssertEqual($0 as? ServerRPCError, .acceptedOperationRequired)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
    }

    func testReadOnlyLegacyDownloadStillReturnsExactContents() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let source = try createTestFile(in: home, name: "source", content: "download contents")
        let input = Pipe()
        let output = Pipe()
        let contents = try Data(contentsOf: source)
        input.fileHandleForWriting.write(legacyFrame(direction: 2, source: source.path, destination: "/unused", count: Int64(contents.count)))
        try input.fileHandleForWriting.close()
        try TransferMode(input: input.fileHandleForReading, output: output.fileHandleForWriting).run()
        try output.fileHandleForWriting.close()
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), contents)
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    private func legacyFrame(direction: UInt8, source: String, destination: String, count: Int64) -> Data {
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt8(direction)
        writer.writeData(Data(source.utf8))
        writer.writeData(Data(destination.utf8))
        writer.writeInt64(count)
        var length = UInt32(writer.data.count).bigEndian
        return Data(bytes: &length, count: 4) + writer.data
    }
}
