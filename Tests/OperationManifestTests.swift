import Foundation
import RemoteOperationSupport
import XCTest

final class OperationManifestTests: XCTestCase {
    func testManifestIncludesSortedPathsEmptyDirectoriesAndUnfollowedLinks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tree = fixture.root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: tree.appendingPathComponent("with space"))
        try Data().write(to: tree.appendingPathComponent("zero"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("loop").path, withDestinationPath: ".")
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        var measured: [UInt64] = []
        let manifest = try parent.manifest(Data("tree".utf8)) { measured.append($0) }
        XCTAssertEqual(manifest.entries.map(\.relativePath), ["", "empty", "loop", "with space", "zero"].map { Data($0.utf8) })
        XCTAssertEqual(manifest.entries.map { $0.observation.kind }, [.directory, .directory, .symbolicLink, .file, .file])
        XCTAssertEqual(manifest.entries[2].observation.linkTarget, Data(".".utf8))
        XCTAssertEqual(manifest.entries[3].observation.sha256, try OperationContentProof.data(Data("abc".utf8)).sha256)
        XCTAssertEqual(manifest.proof.byteCount, 3)
        XCTAssertEqual(measured, measured.sorted())
        XCTAssertEqual(measured.last, 3)
        let encoded = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(OperationManifest.self, from: encoded), manifest)
        try FileManager.default.copyItem(at: tree, to: fixture.root.appendingPathComponent("copy"))
        let copied = try parent.manifest(Data("copy".utf8), progress: { _ in })
        XCTAssertEqual(copied.proof, manifest.proof)
        XCTAssertNotEqual(copied.entries.first?.observation.identity, manifest.entries.first?.observation.identity)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("new-empty"), withIntermediateDirectories: false)
        XCTAssertNotEqual(try parent.manifest(Data("tree".utf8), progress: { _ in }).proof, manifest.proof)
    }

    func testManifestRejectsMutationDuringReadingAndCanBeCancelled() throws {
        for mutate in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let file = fixture.root.appendingPathComponent("file")
            try Data(repeating: 42, count: 131_072).write(to: file)
            let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
            var changed = false
            XCTAssertThrowsError(try parent.manifest(Data("file".utf8)) { count in
                guard count > 0 else { return }
                if !mutate { throw OperationContractError.cancelled }
                if !changed {
                    changed = true
                    try Data("changed".utf8).write(to: file)
                }
            }) { error in
                if mutate {
                    XCTAssertEqual(error as? OperationFilesystemError, .identityChanged)
                } else {
                    XCTAssertEqual(error as? OperationContractError, .cancelled)
                }
            }
        }
    }

    func testManifestRejectsAChildAddedDuringEnumeration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tree = fixture.root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("contents".utf8).write(to: tree.appendingPathComponent("first"))
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        var changed = false
        XCTAssertThrowsError(try parent.manifest(Data("tree".utf8)) { count in
            if count > 0, !changed {
                changed = true
                try Data("new child".utf8).write(to: tree.appendingPathComponent("later"))
            }
        }) { error in
            XCTAssertEqual(error as? OperationFilesystemError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: tree.appendingPathComponent("later")), Data("new child".utf8))
    }

    func testArchiveInputsFollowFileAndDirectoryLinksWithoutChangingSources() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tree = fixture.root.appendingPathComponent("tree")
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("referent".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("file-link").path, withDestinationPath: "../outside/file")
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("folder-link").path, withDestinationPath: "../outside")
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        let name = Data("tree".utf8)
        let original = try parent.manifest(name, progress: { _ in })
        let preserved = try parent.archiveInputs(name, followingLinks: false, progress: { _ in })
        XCTAssertEqual(preserved.manifest, original)
        var measured: [UInt64] = []
        let followed = try parent.archiveInputs(name, followingLinks: true) { measured.append($0) }
        XCTAssertEqual(followed.manifest.entries.map(\.relativePath), ["", "file-link", "folder-link", "folder-link/file"].map { Data($0.utf8) })
        XCTAssertEqual(followed.manifest.entries.map { $0.observation.kind }, [.directory, .file, .directory, .file])
        XCTAssertEqual(followed.manifest.proof.byteCount, 16)
        XCTAssertEqual(measured, measured.sorted())
        XCTAssertEqual(measured.last, 16)
        XCTAssertEqual(followed.locations[Data("file-link".utf8)], followed.locations[Data("folder-link/file".utf8)])
        XCTAssertEqual(try parent.manifest(name, progress: { _ in }), original)
    }

    func testArchiveInputsRejectCyclesDanglingLinksAndChangedReferents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        for target in [".", "missing", "loop"] {
            let tree = fixture.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("loop").path, withDestinationPath: target)
            XCTAssertThrowsError(try parent.archiveInputs(Data(tree.lastPathComponent.utf8), followingLinks: true, progress: { _ in }))
        }
        let file = fixture.root.appendingPathComponent("file")
        try Data(repeating: 42, count: 131_072).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias").path, withDestinationPath: "file")
        var changed = false
        XCTAssertThrowsError(try parent.archiveInputs(Data("alias".utf8), followingLinks: true) { count in
            if count > 0, !changed {
                changed = true
                try Data("changed".utf8).write(to: file)
            }
        }) { error in
            XCTAssertEqual(error as? OperationFilesystemError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("changed".utf8))
    }

    #if os(Linux)
    func testManifestPreservesNonUTF8PathBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        _ = try parent.createDirectory(Data("tree".utf8))
        let tree = try OperationDirectory(path: parent.childPath(Data("tree".utf8)))
        let name = Data([255, 10, 37])
        let (handle, _) = try tree.createExclusiveFile(name)
        try handle.write(contentsOf: Data("bytes".utf8))
        try handle.close()
        let manifest = try parent.manifest(Data("tree".utf8), progress: { _ in })
        XCTAssertEqual(manifest.entries.map(\.relativePath), [Data(), name])
        XCTAssertEqual(manifest.proof.byteCount, 5)
    }
    #endif

    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
