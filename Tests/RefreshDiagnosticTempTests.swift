import AppKit
import XCTest
@testable import Detours

@MainActor
final class RefreshDiagnosticTempTests: XCTestCase {
    func testDiagnoseLocalDestinationPolicyFlow() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let destDir = try createTestFolder(in: temp, name: "dest")
        _ = try createTestFile(in: destDir, name: "0_first.txt")
        let copied = try createTestFile(in: destDir, name: "m_copied.txt")

        let fileList = FileListViewController()
        fileList.loadDirectory(destDir)
        print("DIAG viewLoaded=\(fileList.isViewLoaded) currentDir=\(String(describing: fileList.currentDirectory))")

        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [.local(copied)]
        var applied = false
        policy.onApplied = { applied = true }
        fileList.refreshScheduler.submitListingRefresh(
            directory: .local(destDir), cause: .operation, policy: policy
        )
        print("DIAG submitted, epoch=\(fileList.refreshScheduler.epoch) inFlight=\(fileList.refreshScheduler.isRefreshInFlight)")

        fileList.loadViewIfNeeded()
        fileList.view.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        fileList.view.layoutSubtreeIfNeeded()
        print("DIAG after viewload epoch=\(fileList.refreshScheduler.epoch) inFlight=\(fileList.refreshScheduler.isRefreshInFlight) navInFlight=\(fileList.isNavigationLoadInFlight)")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if applied { break }
        }
        print("DIAG end applied=\(applied) rows=\(fileList.tableView.numberOfRows) selected=\(fileList.selectedItems.map(\.name)) navInFlight=\(fileList.isNavigationLoadInFlight) epoch=\(fileList.refreshScheduler.epoch) inFlight=\(fileList.refreshScheduler.isRefreshInFlight) rootLoc=\(String(describing: fileList.dataSource.displayedRootLocation))")
        XCTAssertTrue(applied)
    }
}
