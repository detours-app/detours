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
}
