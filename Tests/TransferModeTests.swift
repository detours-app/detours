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

    func testCompleteUploadWritesDestinationAndLeavesNoPartial() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let folder = home.appendingPathComponent("2026-09-01T1028/report", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("Exam Report Best Practice.pdf")
        let partial = folder.appendingPathComponent("Exam Report Best Practice.pdf.detours-partial")
        let body = Data(repeating: 0x42, count: 200_000)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt8(1)
        writer.writeData(Data("/unused-source".utf8))
        writer.writeData(Data(destination.path.utf8))
        writer.writeInt64(Int64(body.count))
        let header = writer.data
        var frameLength = UInt32(header.count).bigEndian
        let framePrefix = Data(bytes: &frameLength, count: MemoryLayout<UInt32>.size)
        let feeder = Thread {
            inputPipe.fileHandleForWriting.write(framePrefix + header)
            inputPipe.fileHandleForWriting.write(body)
            try? inputPipe.fileHandleForWriting.close()
        }
        feeder.start()

        try TransferMode(
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            trashOperations: TrashOperations(homeDirectory: home)
        ).run()

        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testUploadIntoMissingFolderReportsTheSystemError() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let destination = home.appendingPathComponent("missing/report.pdf")
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt8(1)
        writer.writeData(Data("/unused-source".utf8))
        writer.writeData(Data(destination.path.utf8))
        writer.writeInt64(3)
        var frameLength = UInt32(writer.data.count).bigEndian
        let framePrefix = Data(bytes: &frameLength, count: MemoryLayout<UInt32>.size)
        inputPipe.fileHandleForWriting.write(framePrefix + writer.data)
        inputPipe.fileHandleForWriting.write(Data("abc".utf8))
        try inputPipe.fileHandleForWriting.close()

        XCTAssertThrowsError(
            try TransferMode(
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting,
                trashOperations: TrashOperations(homeDirectory: home)
            ).run()
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOENT, "The real system error must reach the caller: \(error)")
        }
    }

    func testShortUploadRestoresDisplacedDestinationAndRemovesPartial() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let destination = try createTestFile(in: home, name: "destination.bin", content: "original")
        let partial = home.appendingPathComponent("destination.bin.detours-partial")
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt8(1)
        writer.writeData(Data("/unused-source".utf8))
        writer.writeData(Data(destination.path.utf8))
        writer.writeInt64(8)
        var frameLength = UInt32(writer.data.count).bigEndian
        let framePrefix = Data(bytes: &frameLength, count: MemoryLayout<UInt32>.size)
        inputPipe.fileHandleForWriting.write(framePrefix + writer.data)
        inputPipe.fileHandleForWriting.write(Data("abc".utf8))
        try inputPipe.fileHandleForWriting.close()

        XCTAssertThrowsError(
            try TransferMode(
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting,
                trashOperations: TrashOperations(homeDirectory: home)
            ).run()
        ) { error in
            XCTAssertEqual(
                error as? TransferModeError,
                .byteCountMismatch(expected: 8, actual: 3)
            )
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let trashFiles = home.appendingPathComponent(".local/share/Trash/files")
        let trashInfo = home.appendingPathComponent(".local/share/Trash/info")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashFiles.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashInfo.path), [])
    }
}
