import Darwin
import DetoursProcess
import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteTransferArchiveTests: XCTestCase {
    func testTransferArchivePreservesEmptyFoldersFilesAndRelativeLinks() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let folder = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("verified child".utf8).write(to: folder.appendingPathComponent("é child"))
        try Data().write(to: folder.appendingPathComponent("zero"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "é child")
        var linkBytes = [UInt8](repeating: 0, count: 1024)
        let linkLength = folder.appendingPathComponent("link").path.withCString { readlink($0, &linkBytes, 1024) }
        guard linkLength > 0 else { return XCTFail("Cannot read original link bytes") }
        let originalLink = Data(linkBytes.prefix(linkLength))
        let workspace = try OperationWorkspace(parent: OperationDirectory(path: Data(root.path.utf8)),
            id: .init(operation: UUID(), item: UUID()))
        let output = try workspace.createFile(named: Data("transfer.zip".utf8))
        let manifest = try RemoteTransferArchive.write(folder: folder, output: output, progress: { _ in })
        try output.close()
        let input = try workspace.directory.openFile(Data("transfer.zip".utf8))
        defer { try? input.close() }
        let extracted = root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let members = try SevenZipArchiveReader.read(input: input, format: .zip, password: nil, output: { member in
            let file = extracted.appendingPathComponent(String(member.index))
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw OperationFilesystemError.unsupported }
            return try FileHandle(forWritingTo: file)
        }, progress: { _ in })
        let names = members.map { $0.directory && $0.name.hasSuffix("/") ? String($0.name.dropLast()) : $0.name }
        XCTAssertEqual(Set(names), ["tree", "tree/empty", "tree/é child", "tree/zero", "tree/link"])
        XCTAssertEqual(members.filter(\.directory).count, 2)
        XCTAssertEqual(manifest.entries.count, 5)
        let child = try XCTUnwrap(members.first { $0.name == "tree/é child" })
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(String(child.index))), Data("verified child".utf8))
        let zero = try XCTUnwrap(members.first { $0.name == "tree/zero" })
        XCTAssertEqual(zero.size, 0)
        let link = try XCTUnwrap(members.first { $0.name == "tree/link" })
        XCTAssertEqual(link.mode & 0o170000, 0o120000)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(String(link.index))), originalLink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path), "é child")
    }

    func testChangedStagedChildCannotProduceVerifiedTreePayload() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let folder = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("child")
        try Data(repeating: 65, count: 131_072).write(to: child)
        let workspace = try OperationWorkspace(parent: OperationDirectory(path: Data(root.path.utf8)),
            id: .init(operation: UUID(), item: UUID()))
        let output = try workspace.createFile(named: Data("transfer.zip".utf8))
        defer { try? output.close() }
        XCTAssertThrowsError(try RemoteTransferArchive.write(folder: folder, output: output) { _ in
            try Data("changed child".utf8).write(to: child)
        })
        XCTAssertEqual(try Data(contentsOf: child), Data("changed child".utf8))
    }
}
