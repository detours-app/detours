import Foundation
import RemoteOperationSupport
import XCTest

final class OperationContentProofTests: XCTestCase {
    func testKnownDigestsAndMeasuredProgressAcrossChunkBoundaries() throws {
        let vectors: [(Data, String)] = [
            (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (Data(repeating: 97, count: 1_000_000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"),
        ]
        for (bytes, expected) in vectors {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            try bytes.write(to: root.appendingPathComponent("payload"))
            let directory = try OperationDirectory(path: Data(root.path.utf8))
            var progress: [UInt64] = []
            let proof = try directory.proveFile(Data("payload".utf8)) { progress.append($0) }
            XCTAssertEqual(proof.sha256, expected)
            XCTAssertEqual(try OperationContentProof.data(bytes).sha256, expected)
            XCTAssertEqual(proof.byteCount, UInt64(bytes.count))
            XCTAssertEqual(progress.last ?? 0, UInt64(bytes.count))
            XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    func testCancellationStopsHashing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 1_000_000).write(to: root.appendingPathComponent("payload"))
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        XCTAssertThrowsError(try directory.proveFile(Data("payload".utf8)) { _ in throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
