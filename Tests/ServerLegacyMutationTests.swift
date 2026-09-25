import Foundation
import RemoteOperationSupport
import XCTest
@testable import detours_server

final class ServerLegacyMutationTests: XCTestCase {
    func testLegacyRPCMutationsRefuseBeforeChangingFiles() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        try Data("original".utf8).write(to: fixture.destination)
        let partial = fixture.destination.appendingPathExtension("detours-partial")
        try Data("another operation".utf8).write(to: partial)
        let path = ServerRemotePath(fixture.destination.path)
        let folder = ServerRemotePath(fixture.root.appendingPathComponent("new-folder").path)
        let messages: [ServerRPCMessage] = [
            .copy(sources: [path], destination: folder, maximumRPCBytes: 1),
            .move(sources: [path], destination: folder), .rename(item: path, newName: Data("renamed".utf8)),
            .delete(items: [path]), .trash(items: [path]), .restoreFromTrash(items: [path]), .mkDir(path: folder),
            .symlink(path: folder, targetPath: path),
            .archiveCreate(items: [path], format: "zip", archiveName: Data("archive".utf8), password: nil),
            .archiveExtract(archive: path, password: nil),
            .upload(path: path, contents: Data("replacement".utf8), expectedByteCount: 11, maximumRPCBytes: 100),
        ]
        let handler = RPCHandler(operationService: fixture.service)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        for message in messages {
            try XCTAssertThrowsError(try handler.handleChunks(message: message)) { error in
                XCTAssertEqual(error as? ServerRPCError, .acceptedOperationRequired)
                var reader = ServerRPCBinaryReader(data: RPCHandler.encodeError(error))
                XCTAssertEqual(try reader.readString(), "Remote helper compatibility error: changes require an accepted operation using protocol version 2.")
                XCTAssertNoThrow(try reader.requireComplete())
            }
            XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("original".utf8))
            XCTAssertEqual(try Data(contentsOf: partial), Data("another operation".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(), names)
        }
        XCTAssertEqual(try handler.handle(message: .download(path: path, maximumRPCBytes: 100)), Data("original".utf8))
    }

    func testLegacyStreamUploadRefusesBeforeReadingBodyOrChangingFiles() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        try Data("original".utf8).write(to: fixture.destination)
        let partial = fixture.destination.appendingPathExtension("detours-partial")
        try Data("another operation".utf8).write(to: partial)
        var writer = ServerRPCBinaryWriter()
        writer.writeUInt8(1)
        writer.writeData(Data("/unused-source".utf8))
        writer.writeData(Data(fixture.destination.path.utf8))
        writer.writeInt64(1_048_577)
        var length = UInt32(writer.data.count).bigEndian
        let inputURL = fixture.root.appendingPathComponent("input")
        let outputURL = fixture.root.appendingPathComponent("output")
        try (Data(bytes: &length, count: 4) + writer.data).write(to: inputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try SafeFileWriter.createHandle(at: outputURL)
        defer { try? input.close(); try? output.close() }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        XCTAssertThrowsError(try TransferMode(input: input, output: output, operationService: fixture.service).run()) {
            XCTAssertEqual($0 as? ServerRPCError, .acceptedOperationRequired)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: partial), Data("another operation".utf8))
        XCTAssertEqual(try Data(contentsOf: outputURL), Data())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(), names)
    }

    private struct Fixture {
        let root: URL
        let destination: URL
        let service: ServerOperationService

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            service = try await ServerOperationService(root: root.appendingPathComponent("journal"),
                                                        account: .init(hostIdentity: "fixture", accountIdentity: "fixture-user"), homeDirectory: root)
        }

        func cleanup() { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
    }
}
