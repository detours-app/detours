import AppKit
import XCTest
import QualificationSupport
@testable import Detours

@MainActor
final class QualificationWorkflowTests: XCTestCase {
    private var repetitions: Int {
        Int(ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REPETITIONS"] ?? "") ?? 100
    }

    private var seed: UInt64 {
        UInt64(ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_SEED"] ?? "") ?? 0
    }

    private var roots: [URL] throws {
        try ["LOCAL_ROOT", "APFS_ROOT", "ICLOUD_ROOT", "SMB_ROOT"].map { key in
            let value = try XCTUnwrap(ProcessInfo.processInfo.environment[key], "Missing \(key)")
            return URL(fileURLWithPath: value, isDirectory: true)
        }
    }

    func testActivationWorkflow() throws {
        let roots = try roots
        for iteration in 0..<repetitions {
            let split = MainSplitViewController()
            split.loadViewIfNeeded()
            let root = roots[index(for: iteration, count: roots.count)]
            _ = split.leftPane.createTab(at: root, select: true)
            split.setActivePane(iteration.isMultiple(of: 2) ? 0 : 1)
            split.switchToOtherPane()

            XCTAssertNotEqual(split.leftPane.isActive, split.rightPane.isActive)
            XCTAssertNotNil(split.leftPane.selectedTab)
            XCTAssertNotNil(split.rightPane.selectedTab)
            shutdown(split)
        }
    }

    func testRefreshWorkflow() async throws {
        let roots = try roots
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "refresh", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let first = scenario.appendingPathComponent("first.txt")
            try Data("first".utf8).write(to: first)
            let initial = try await LocalFileProvider.shared.list(.local(scenario), showHidden: true)
            XCTAssertEqual(initial.map(\.name), ["first.txt"])

            let renamed = try await LocalFileProvider.shared.rename(.local(first), to: "renamed.txt")
            let refreshed = try await LocalFileProvider.shared.list(.local(scenario), showHidden: true)
            XCTAssertEqual(renamed.lastPathComponent, "renamed.txt")
            XCTAssertEqual(refreshed.map(\.name), ["renamed.txt"])
        }
    }

    func testTransferWorkflow() async throws {
        let roots = try roots
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "transfer", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let source = scenario.appendingPathComponent("source.txt")
            let copiedDirectory = scenario.appendingPathComponent("copied", isDirectory: true)
            let movedDirectory = scenario.appendingPathComponent("moved", isDirectory: true)
            try Data("payload-\(iteration)".utf8).write(to: source)
            try FileManager.default.createDirectory(at: copiedDirectory, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: movedDirectory, withIntermediateDirectories: false)

            let copied = try await FileOperationQueue.shared.copy(items: [source], to: copiedDirectory)
            let moved = try await FileOperationQueue.shared.move(items: copied, to: movedDirectory)
            XCTAssertEqual(try String(contentsOf: moved[0], encoding: .utf8), "payload-\(iteration)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: copied[0].path))
        }
    }

    func testMutationWorkflow() async throws {
        let roots = try roots
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "mutation", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let queue = FileOperationQueue.shared
            let folder = try await queue.createFolder(in: scenario, name: "created")
            let file = try await queue.createFile(in: folder, name: "item.txt", content: Data("body".utf8))
            let renamed = try await queue.rename(item: file, to: "renamed.txt")
            let duplicated = try await queue.duplicate(items: [renamed])

            XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
            XCTAssertEqual(duplicated.count, 1)
            try await queue.deleteImmediately(items: duplicated)
            XCTAssertFalse(FileManager.default.fileExists(atPath: duplicated[0].path))
        }
    }

    func testConnectionWorkflow() throws {
        let targets = ["devtest", "wraith", "win-carriercall"]
        for target in targets {
            for _ in 0..<repetitions {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", target, "true"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, "SSH connection failed: \(target)")
            }
        }
    }

    func testArchiveWorkflow() async throws {
        let roots = try roots
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "archive", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let source = scenario.appendingPathComponent("source.txt")
            try Data("archive-\(iteration)".utf8).write(to: source)
            let archive = try await FileOperationQueue.shared.archive(
                items: [source], format: .zip, archiveName: "bundle", password: nil
            )
            let extracted = try await FileOperationQueue.shared.extract(archive: archive, password: nil)
            XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
        }
    }

    func testSessionWorkflow() throws {
        let roots = try roots
        for iteration in 0..<repetitions {
            let pane = PaneViewController()
            pane.loadViewIfNeeded()
            let first = roots[index(for: iteration, count: roots.count)]
            let second = roots[index(for: iteration + 1, count: roots.count)]
            _ = pane.createTab(at: first, select: true)
            _ = pane.createTab(at: second, select: true)
            let selected = pane.selectedTab?.id
            pane.selectPreviousTab()
            pane.selectNextTab()
            XCTAssertEqual(pane.selectedTab?.id, selected)
            for tab in pane.tabs { tab.fileListViewControllerIfLoaded?.shutdown() }
        }
    }

    func testOpeningWorkflow() async throws {
        let roots = try roots
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "opening", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let file = scenario.appendingPathComponent("preview.txt")
            try Data("preview-\(iteration)".utf8).write(to: file)
            let quickLook = try await LocalFileProvider.shared.openForQuickLook(.local(file))
            XCTAssertEqual(try String(contentsOf: quickLook, encoding: .utf8), "preview-\(iteration)")
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: file),
                .plainText(language: "plaintext")
            )
        }
    }

    private func index(for iteration: Int, count: Int) -> Int {
        var value = seed &+ UInt64(iteration) &* 0x9e3779b97f4a7c15
        value ^= value >> 30
        value &*= 0xbf58476d1ce4e5b9
        value ^= value >> 27
        value &*= 0x94d049bb133111eb
        value ^= value >> 31
        return Int(value % UInt64(count))
    }

    private func makeScenario(group: String, iteration: Int, roots: [URL]) throws -> URL {
        let root = roots[index(for: iteration, count: roots.count)]
        let scenario = root.appendingPathComponent("workflow-\(group)-\(seed)-\(iteration)", isDirectory: true)
        try validate(scenario, under: root)
        try FileManager.default.createDirectory(at: scenario, withIntermediateDirectories: false)
        return scenario
    }

    private func validatedCleanup(_ scenario: URL) {
        let root = scenario.deletingLastPathComponent()
        do {
            try validate(scenario, under: root)
            try FileManager.default.removeItem(at: scenario)
        } catch {
            XCTFail("Guarded cleanup failed: \(error)")
        }
    }

    private func validate(_ candidate: URL, under root: URL) throws {
        let sentinel = root.appendingPathComponent(QualificationRunRootDescriptor.sentinelFileName)
        let descriptor = try QualificationRunRootGuard().readDescriptor(at: sentinel)
        try QualificationRunRootGuard().validate(descriptor: descriptor, candidate: candidate)
    }

    private func shutdown(_ split: MainSplitViewController) {
        for pane in [split.leftPane, split.rightPane] {
            for tab in pane.tabs { tab.fileListViewControllerIfLoaded?.shutdown() }
        }
    }
}
