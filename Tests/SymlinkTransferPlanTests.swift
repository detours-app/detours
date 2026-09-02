import XCTest
@testable import Detours

/// The link walk that decides what each nested link becomes when a folder crosses hosts.
final class SymlinkTransferPlanTests: XCTestCase {
    private let host = UUID()

    private func location(_ path: String) -> Location { .remote(hostID: host, path: path) }

    func testLinkInsideRootIsRecordedAsRelativeLink() async throws {
        let provider = SymlinkFakeProvider(hostID: host, nodes: [
            "/root": .directory,
            "/root/a": .directory,
            "/root/a/link": .link("../hop"),
            "/root/hop": .link("data/file.txt"),
            "/root/data": .directory,
            "/root/data/file.txt": .file(Data("f".utf8)),
        ])
        let staged = try createTempDirectory()
        defer { cleanupTempDirectory(staged) }
        let context = SymlinkWalkContext(rootPath: "/root", rootStagedURL: staged)

        let outcome = try await SymlinkTransferWalker(provider: provider).classify(
            link: location("/root/a/link"),
            name: "link",
            stagedLink: staged.appendingPathComponent("a/link"),
            context: context
        )

        XCTAssertEqual(outcome, .recreate(relativeTarget: "../data/file.txt"))

        let failures = try await SymlinkTransferWalker(provider: provider).stage(location("/root"), to: staged)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: staged.appendingPathComponent("a/link").path),
            "../data/file.txt"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: staged.appendingPathComponent("hop").path),
            "data/file.txt"
        )
    }

    func testLinkOutsideRootIsFollowed() async throws {
        let provider = SymlinkFakeProvider(hostID: host, nodes: [
            "/root": .directory,
            "/root/first": .link("/outside/dir"),
            "/root/second": .link("../outside/dir"),
            "/outside": .directory,
            "/outside/dir": .directory,
            "/outside/dir/f.txt": .file(Data("shared".utf8)),
        ])
        let staged = try createTempDirectory()
        defer { cleanupTempDirectory(staged) }
        let walker = SymlinkTransferWalker(provider: provider)
        let context = SymlinkWalkContext(rootPath: "/root", rootStagedURL: staged)

        for name in ["first", "second"] {
            let outcome = try await walker.classify(
                link: location("/root/\(name)"),
                name: name,
                stagedLink: staged.appendingPathComponent(name),
                context: context
            )
            XCTAssertEqual(outcome, .follow(location("/outside/dir"), isDirectory: true), name)
        }

        let failures = try await walker.stage(location("/root"), to: staged)
        XCTAssertTrue(failures.isEmpty)
        for name in ["first", "second"] {
            let copied = staged.appendingPathComponent(name)
            let values = try copied.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            XCTAssertEqual(values.isSymbolicLink, false, name)
            XCTAssertEqual(values.isDirectory, true, name)
            XCTAssertEqual(try String(contentsOf: copied.appendingPathComponent("f.txt"), encoding: .utf8), "shared")
        }
    }

    func testAbsoluteLinkInsideRootIsStillInside() async throws {
        let provider = SymlinkFakeProvider(hostID: host, nodes: [
            "/root": .directory,
            "/root/abs": .link("/root/data/file.txt"),
            "/root/data": .directory,
            "/root/data/file.txt": .file(Data("f".utf8)),
        ])
        let staged = try createTempDirectory()
        defer { cleanupTempDirectory(staged) }

        let outcome = try await SymlinkTransferWalker(provider: provider).classify(
            link: location("/root/abs"),
            name: "abs",
            stagedLink: staged.appendingPathComponent("abs"),
            context: SymlinkWalkContext(rootPath: "/root", rootStagedURL: staged)
        )

        XCTAssertEqual(outcome, .recreate(relativeTarget: "data/file.txt"))
    }

    func testReenteredDirectoryFailsWithLinkLoops() async throws {
        let provider = SymlinkFakeProvider(hostID: host, nodes: [
            "/root": .directory,
            "/root/keep.txt": .file(Data("k".utf8)),
            "/root/sub": .directory,
            "/root/sub/back": .link(".."),
            "/root/x": .link("y"),
            "/root/y": .link("x"),
        ])
        let staged = try createTempDirectory()
        defer { cleanupTempDirectory(staged) }
        let walker = SymlinkTransferWalker(provider: provider)
        var context = SymlinkWalkContext(rootPath: "/root", rootStagedURL: staged)
        context.activeDirectories = ["/root", "/root/sub"]

        await assertLinkError(
            try await walker.classify(
                link: location("/root/sub/back"),
                name: "back",
                stagedLink: staged.appendingPathComponent("sub/back"),
                context: context
            ),
            expected: .linkLoops(name: "back"),
            message: "The link back leads in a loop."
        )
        await assertLinkError(
            try await walker.resolveFinalTarget(of: location("/root/x"), name: "x"),
            expected: .linkLoops(name: "x"),
            message: "The link x leads in a loop."
        )

        let failures = try await walker.stage(location("/root"), to: staged)
        XCTAssertEqual(failures.map(\.0.path).sorted(), ["/root/sub/back", "/root/x", "/root/y"])
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("keep.txt"), encoding: .utf8), "k")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("sub/back").path))
    }

    func testMissingTargetFailsWithLinkTargetMissing() async throws {
        let provider = SymlinkFakeProvider(hostID: host, nodes: [
            "/root": .directory,
            "/root/gone": .link("hop"),
            "/root/hop": .link("nowhere.txt"),
        ])
        let staged = try createTempDirectory()
        defer { cleanupTempDirectory(staged) }
        let walker = SymlinkTransferWalker(provider: provider)

        await assertLinkError(
            try await walker.resolveFinalTarget(of: location("/root/gone"), name: "gone"),
            expected: .linkTargetMissing(name: "gone"),
            message: "The link gone points to an item that does not exist."
        )

        let failures = try await walker.stage(location("/root"), to: staged)
        XCTAssertEqual(failures.map(\.0.path).sorted(), ["/root/gone", "/root/hop"])
    }

    private func assertLinkError<T>(
        _ body: @autoclosure () async throws -> T,
        expected: FileOperationError,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as FileOperationError {
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
            XCTAssertEqual(error.errorDescription, message, file: file, line: line)
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }
}
