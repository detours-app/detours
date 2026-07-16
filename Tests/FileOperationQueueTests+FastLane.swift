import XCTest
@testable import Detours

extension FileOperationQueueTests {
    // MARK: - Fast-Lane Tests

    /// Blocks until `currentOperation` becomes non-nil or the deadline elapses.
    private func waitForHeavyOperationActive(deadline: TimeInterval = 2.0) async {
        let end = Date().addingTimeInterval(deadline)
        while FileOperationQueue.shared.currentOperation == nil, Date() < end {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func makeHeavySource(in temp: URL, name: String = "HeavySrc", fileSize: Int = 15_000_000) throws -> URL {
        let dir = try createTestFolder(in: temp, name: name)
        let file = dir.appendingPathComponent("big.bin")
        try Data(count: fileSize).write(to: file)
        return dir
    }

    func testDeleteAncestorOfProtectedPathIsNotFastLaneEligible() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let ancestor = try createTestFolder(in: temp, name: "Ancestor")
        let protected = try createTestFolder(in: ancestor, name: "Protected")
        let queue = FileOperationQueue.shared
        queue.enterProtectedPaths([protected])
        defer { queue.leaveProtectedPaths([protected]) }

        let eligible = await queue.isFastLaneCandidateForTesting(
            sources: [.local(ancestor)],
            destination: nil
        )
        XCTAssertFalse(eligible)
    }

    func testFastLaneRenameDuringUnrelatedBulkCopy() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let heavySrc = try makeHeavySource(in: temp)
        let heavyDst = try createTestFolder(in: temp, name: "HeavyDst")
        let unrelatedDir = try createTestFolder(in: temp, name: "UnrelatedDir")
        let unrelatedFile = try createTestFile(in: unrelatedDir, name: "a.txt")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        let heavyTask = Task { try? await queue.copy(items: [heavySrc], to: heavyDst) }
        await waitForHeavyOperationActive()
        XCTAssertNotNil(queue.currentOperation, "Heavy copy should be active")

        let renamed = try await queue.rename(item: unrelatedFile, to: "b.txt")
        XCTAssertEqual(renamed.lastPathComponent, "b.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))

        _ = await heavyTask.value

        XCTAssertEqual(startedOps.count, 1, "Rename during unrelated copy must stay on fast lane (heavy callbacks unchanged)")
    }

    func testFastLaneCreateFolderDuringUnrelatedBulkCopy() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let heavySrc = try makeHeavySource(in: temp)
        let heavyDst = try createTestFolder(in: temp, name: "HeavyDst")
        let unrelatedDir = try createTestFolder(in: temp, name: "Unrelated")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        let heavyTask = Task { try? await queue.copy(items: [heavySrc], to: heavyDst) }
        await waitForHeavyOperationActive()
        XCTAssertNotNil(queue.currentOperation)

        let created = try await queue.createFolder(in: unrelatedDir, name: "Notes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))

        _ = await heavyTask.value
        XCTAssertEqual(startedOps.count, 1, "Create folder must stay on fast lane")
    }

    func testFastLaneCreateFolderInParentDirectoryOfProtectedPath() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let heavySrc = try makeHeavySource(in: temp)
        let heavyDst = try createTestFolder(in: temp, name: "HeavyDst")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        let heavyTask = Task { try? await queue.copy(items: [heavySrc], to: heavyDst) }
        await waitForHeavyOperationActive()
        XCTAssertNotNil(queue.currentOperation)

        let created = try await queue.createFolder(in: temp, name: "SiblingFolder")
        XCTAssertEqual(created.lastPathComponent, "SiblingFolder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))

        _ = await heavyTask.value
        XCTAssertEqual(startedOps.count, 1, "Parent-directory sibling work should stay on fast lane")
    }

    func testFastLaneDeleteDuringUnrelatedBulkCopy() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let heavySrc = try makeHeavySource(in: temp)
        let heavyDst = try createTestFolder(in: temp, name: "HeavyDst")
        let unrelatedDir = try createTestFolder(in: temp, name: "Unrelated")
        let victim = try createTestFile(in: unrelatedDir, name: "doomed.txt")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        let heavyTask = Task { try? await queue.copy(items: [heavySrc], to: heavyDst) }
        await waitForHeavyOperationActive()

        let undoManager = UndoManager()
        try await queue.delete(items: [victim], undoManager: undoManager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))

        undoManager.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))

        _ = await heavyTask.value
        XCTAssertEqual(startedOps.count, 1, "Delete must stay on fast lane")
    }

    func testFastLaneSmallCopyDuringUnrelatedBulkCopy() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let heavySrc = try makeHeavySource(in: temp)
        let heavyDst = try createTestFolder(in: temp, name: "HeavyDst")
        let smallSrcDir = try createTestFolder(in: temp, name: "SmallSrc")
        let smallFile = try createTestFile(in: smallSrcDir, name: "note.txt")
        let smallDstDir = try createTestFolder(in: temp, name: "SmallDst")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        let heavyTask = Task { try? await queue.copy(items: [heavySrc], to: heavyDst) }
        await waitForHeavyOperationActive()

        let copied = try await queue.copy(items: [smallFile], to: smallDstDir)
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied[0].path))

        _ = await heavyTask.value
        XCTAssertEqual(startedOps.count, 1, "Small unrelated copy must stay on fast lane")
    }

    func testOverlapGuardKeepsSameTreeRenameOnHeavyLane() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let heavySrc = try createTestFolder(in: temp, name: "HeavySrc")
        let innerFile = try createTestFile(in: heavySrc, name: "inner.txt")
        let big = heavySrc.appendingPathComponent("big.bin")
        try Data(count: 15_000_000).write(to: big)
        let heavyDst = try createTestFolder(in: temp, name: "HeavyDst")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        let heavyTask = Task { try? await queue.copy(items: [heavySrc], to: heavyDst) }
        await waitForHeavyOperationActive()
        XCTAssertNotNil(queue.currentOperation)

        // Rename a file inside the heavy source — overlaps protected paths
        _ = try await queue.rename(item: innerFile, to: "renamed.txt")

        _ = await heavyTask.value

        XCTAssertEqual(startedOps.count, 2, "Overlapping rename must run on heavy lane (copy + rename)")
    }

    func testFastLaneClassifierDirectory() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFolder(in: temp, name: "Source")
        try createTestFile(in: source, name: "inner.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        try await queue.copy(items: [source], to: dest)

        XCTAssertEqual(startedOps.count, 1, "Directory sources always route to heavy lane")
    }

    func testFastLaneClassifierSizeThreshold() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let big = temp.appendingPathComponent("big.bin")
        try Data(count: 11 * 1024 * 1024).write(to: big)
        let small = temp.appendingPathComponent("small.bin")
        try Data(count: 9 * 1024 * 1024).write(to: small)
        let dest = try createTestFolder(in: temp, name: "Dest")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        try await queue.copy(items: [big], to: dest)
        XCTAssertEqual(startedOps.count, 1, "11 MiB file routes to heavy lane")

        try await queue.copy(items: [small], to: dest)
        XCTAssertEqual(startedOps.count, 1, "9 MiB file stays on fast lane")
    }

    func testFastLaneClassifierItemCountThreshold() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let src21 = try createTestFolder(in: temp, name: "Src21")
        var files21: [URL] = []
        for i in 0..<21 {
            files21.append(try createTestFile(in: src21, name: "f\(i).txt"))
        }
        let dst21 = try createTestFolder(in: temp, name: "Dst21")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        try await queue.copy(items: files21, to: dst21)
        XCTAssertEqual(startedOps.count, 1, "21 items route to heavy lane")

        let src20 = try createTestFolder(in: temp, name: "Src20")
        var files20: [URL] = []
        for i in 0..<20 {
            files20.append(try createTestFile(in: src20, name: "f\(i).txt"))
        }
        let dst20 = try createTestFolder(in: temp, name: "Dst20")

        try await queue.copy(items: files20, to: dst20)
        XCTAssertEqual(startedOps.count, 1, "20 items stay on fast lane")
    }

    func testFastLaneReservationPreventsNameRace() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "note.txt", content: "hello")

        let queue = FileOperationQueue.shared
        async let r1 = queue.duplicate(items: [file])
        async let r2 = queue.duplicate(items: [file])
        let (result1, result2) = try await (r1, r2)

        XCTAssertEqual(result1.count, 1)
        XCTAssertEqual(result2.count, 1)
        XCTAssertNotEqual(result1[0].path, result2[0].path, "Concurrent duplicates must produce distinct names")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result1[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result2[0].path))
    }

    func testFastLaneConcurrentCopyKeepsUniqueNameForInFlightDestination() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let sourceDir = try createTestFolder(in: temp, name: "Source")
        let source = sourceDir.appendingPathComponent("payload.bin")
        try Data(count: 9 * 1024 * 1024).write(to: source)
        let destination = try createTestFolder(in: temp, name: "Dest")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        async let first = queue.copy(items: [source], to: destination)
        async let second = queue.copy(items: [source], to: destination)
        let (firstResult, secondResult) = try await (first, second)

        XCTAssertEqual(startedOps.count, 0, "Concurrent small copies should stay on the fast lane")
        let names = Set([firstResult[0].lastPathComponent, secondResult[0].lastPathComponent])
        XCTAssertEqual(names, Set(["payload.bin", "payload copy.bin"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("payload.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("payload copy.bin").path))
    }

    func testFastLaneReservationReleasedOnSuccess() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let queue = FileOperationQueue.shared
        let first = try await queue.createFolder(in: temp, name: "folder")
        let second = try await queue.createFolder(in: temp, name: "folder")

        XCTAssertEqual(first.lastPathComponent, "folder")
        XCTAssertEqual(second.lastPathComponent, "folder 2")
    }

    func testFastLaneReservationReleasedOnError() async throws {
        let temp = try createTempDirectory()
        let readOnly = try createTestFolder(in: temp, name: "ReadOnly")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            cleanupTempDirectory(temp)
        }

        // Make read-only so createDirectory will fail
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)

        let queue = FileOperationQueue.shared
        do {
            _ = try await queue.createFolder(in: readOnly, name: "folder")
            XCTFail("createFolder in read-only directory should throw")
        } catch {
            // expected
        }

        // Restore write permission; the reservation should have been released on error
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)

        let second = try await queue.createFolder(in: readOnly, name: "folder")
        XCTAssertEqual(second.lastPathComponent, "folder", "Reservation must be released on error so the name is reusable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testFastLaneDoesNotFireHeavyCallbacks() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")

        let queue = FileOperationQueue.shared
        var startCalled = false
        var progressCalled = false
        var finishCalled = false

        let savedStart = queue.onOperationStart
        let savedProgress = queue.onProgressUpdate
        let savedFinish = queue.onOperationFinish
        queue.onOperationStart = { _, _ in startCalled = true }
        queue.onProgressUpdate = { _ in progressCalled = true }
        queue.onOperationFinish = { _, _ in finishCalled = true }
        defer {
            queue.onOperationStart = savedStart
            queue.onProgressUpdate = savedProgress
            queue.onOperationFinish = savedFinish
        }

        _ = try await queue.rename(item: file, to: "b.txt")

        XCTAssertFalse(startCalled, "Fast-lane rename must not fire onOperationStart")
        XCTAssertFalse(progressCalled, "Fast-lane rename must not fire onProgressUpdate")
        XCTAssertFalse(finishCalled, "Fast-lane rename must not fire onOperationFinish")
    }

    func testCancelCurrentOperationDoesNotCancelConcurrentFastLaneOp() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let heavySrc = try makeHeavySource(in: temp, fileSize: 30_000_000)
        let heavyDst = try createTestFolder(in: temp, name: "HeavyDst")
        let unrelated = try createTestFolder(in: temp, name: "Unrelated")
        let file = try createTestFile(in: unrelated, name: "a.txt")

        let queue = FileOperationQueue.shared

        let heavyTask = Task { try? await queue.copy(items: [heavySrc], to: heavyDst) }
        await waitForHeavyOperationActive()
        XCTAssertNotNil(queue.currentOperation)

        let renameTask = Task { try await queue.rename(item: file, to: "b.txt") }
        queue.cancelCurrentOperation()

        let renamed = try await renameTask.value
        XCTAssertEqual(renamed.lastPathComponent, "b.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))

        _ = await heavyTask.value
    }

    func testHeavyLaneUnchangedByFastLane() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let heavySrc = try makeHeavySource(in: temp, fileSize: 15_000_000)
        let heavyDst = try createTestFolder(in: temp, name: "HeavyDst")
        let unrelated1 = try createTestFolder(in: temp, name: "U1")
        let unrelated2 = try createTestFolder(in: temp, name: "U2")
        let u1file = try createTestFile(in: unrelated1, name: "a.txt")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        var finishedOps: [FileOperation?] = []
        let savedStart = queue.onOperationStart
        let savedFinish = queue.onOperationFinish
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        queue.onOperationFinish = { op, _ in finishedOps.append(op) }
        defer {
            queue.onOperationStart = savedStart
            queue.onOperationFinish = savedFinish
        }

        let heavyTask = Task { try? await queue.copy(items: [heavySrc], to: heavyDst) }
        await waitForHeavyOperationActive()

        _ = try await queue.rename(item: u1file, to: "b.txt")
        _ = try await queue.createFolder(in: unrelated2, name: "newFolder")

        _ = await heavyTask.value

        XCTAssertEqual(startedOps.count, 1, "Exactly one heavy-lane start")
        XCTAssertEqual(finishedOps.count, 1, "Exactly one heavy-lane finish")
        XCTAssertTrue(FileManager.default.fileExists(atPath: heavyDst.appendingPathComponent("HeavySrc/big.bin").path))
    }

    func testDeleteImmediatelyAlwaysHeavyLane() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        try await queue.deleteImmediately(items: [file])

        XCTAssertEqual(startedOps.count, 1, "deleteImmediately always runs on heavy lane")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testArchiveAlwaysHeavyLane() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt", content: "payload")

        let queue = FileOperationQueue.shared
        var startedOps: [FileOperation] = []
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { op, _ in startedOps.append(op) }
        defer { queue.onOperationStart = savedStart }

        do {
            _ = try await queue.archive(items: [file], format: .zip, archiveName: "bundle", password: nil)
        } catch FileOperationError.archiveToolNotFound {
            // zip should be available on macOS but skip gracefully if not
            throw XCTSkip("zip tool unavailable")
        }

        XCTAssertEqual(startedOps.count, 1, "archive always runs on heavy lane")
    }
}
