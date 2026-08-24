import XCTest
@testable import Detours

/// Renaming an item that an in-flight copy is still writing strands the copy
/// engine mid-walk: the destination tree ends up partial, flagged hidden, or
/// recursively nested into itself. Rename must refuse reserved destinations.
@MainActor
final class RenameGuardTests: XCTestCase {
    private func assertThrowsItemBusy(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected FileOperationError.itemBusy")
        } catch FileOperationError.itemBusy {
            // expected
        } catch {
            XCTFail("Expected FileOperationError.itemBusy, got \(error)")
        }
    }

    func testFastRenameRefusesReservedItem() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Report copy")
        FileOperationQueue.shared.reserveDestination(folder)
        defer { FileOperationQueue.shared.releaseDestination(folder) }

        await assertThrowsItemBusy {
            _ = try await FileOperationQueue.shared.rename(item: folder, to: "Report 2026")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testFastRenameRefusesItemInsideReservedDestination() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Report copy")
        let child = try createTestFile(in: folder, name: "notes.txt")
        FileOperationQueue.shared.reserveDestination(folder)
        defer { FileOperationQueue.shared.releaseDestination(folder) }

        await assertThrowsItemBusy {
            _ = try await FileOperationQueue.shared.rename(item: child, to: "renamed.txt")
        }
    }

    func testQueuedRenameRefusesReservedItem() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Report copy")
        FileOperationQueue.shared.reserveDestination(folder)
        defer { FileOperationQueue.shared.releaseDestination(folder) }

        await assertThrowsItemBusy {
            _ = try await FileOperationQueue.shared.performRename(item: folder, to: "Report 2026")
        }
    }

    func testRenameSucceedsAfterReservationReleased() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Report copy")
        FileOperationQueue.shared.reserveDestination(folder)
        FileOperationQueue.shared.releaseDestination(folder)

        let renamed = try await FileOperationQueue.shared.rename(item: folder, to: "Report 2026")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
    }
}
