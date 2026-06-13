import AppKit
import XCTest
@testable import Detours

@MainActor
final class RemoteUISurfaceTests: XCTestCase {
    func testAddRemoteHostModelUsesSSHTargetOnly() {
        let model = AddRemoteHostModel(suggestions: ["devtest", "prod-vm"])

        model.sshTarget = "dev"
        XCTAssertEqual(model.filteredSuggestions, ["devtest"])

        model.selectSuggestion("devtest")
        XCTAssertEqual(model.sshTarget, "devtest")
        XCTAssertTrue(model.canAdd)

        let host = model.makeHost()
        XCTAssertEqual(host.displayName, "devtest")
        XCTAssertEqual(host.sshTarget, "devtest")
    }

    func testAddRemoteHostRequiresOnlyTarget() {
        let model = AddRemoteHostModel(suggestions: ["devtest", "wraith"])

        model.sshTarget = "wraith"

        XCTAssertEqual(model.filteredSuggestions, ["wraith"])
        XCTAssertTrue(model.canAdd)

        let host = model.makeHost()
        XCTAssertEqual(host.displayName, "wraith")
        XCTAssertEqual(host.sshTarget, "wraith")
    }

    func testDeploySheetModelContainsRequiredSteps() {
        XCTAssertEqual(
            RemoteDeployStep.allCases.map(\.rawValue),
            ["Connecting", "Checking host architecture", "Installing helper", "Starting helper", "Done"]
        )

        let model = DeploySheetModel(hostName: "Dev VM")
        XCTAssertEqual(model.hostName, "Dev VM")
        XCTAssertEqual(model.currentStep, .connecting)

        model.markComplete(.connecting)
        XCTAssertTrue(model.completedSteps.contains(.connecting))
        XCTAssertEqual(model.currentStep, .checkingArchitecture)

        model.markComplete(.done)
        XCTAssertTrue(model.completedSteps.contains(.done))
        XCTAssertEqual(model.currentStep, .done)
    }

    func testConnectionDiagnosticsFullBlockIncludesSummaryAndStderr() {
        let diagnostics = RemoteConnectionDiagnostics(
            summary: "Authentication failed",
            sshStderr: "Permission denied (publickey).",
            daemonStderrTail: "detours-server: failed to start"
        )

        XCTAssertTrue(diagnostics.fullDiagnosticBlock.contains("Authentication failed"))
        XCTAssertTrue(diagnostics.fullDiagnosticBlock.contains("Permission denied (publickey)."))
        XCTAssertTrue(diagnostics.fullDiagnosticBlock.contains("detours-server: failed to start"))
    }

    func testRemoteFileRowsDoNotCarryRemoteHostBadge() {
        let item = FileItem(
            name: "remote.txt",
            location: .remote(hostID: UUID(), path: "/home/maf/remote.txt"),
            isDirectory: false,
            size: 12,
            dateModified: Date(),
            icon: NSImage()
        )
        let cell = FileListCell(frame: NSRect(x: 0, y: 0, width: 300, height: 24))

        cell.configure(with: item)

        XCTAssertNil(descendant(in: cell, accessibilityIdentifier: "remoteHostBreadcrumbBadge"))
        XCTAssertEqual(cell.textField?.stringValue, "remote.txt")
    }

    func testEnterOnRemoteFileDoesNotRequestLocalURL() {
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.dataSource.items = [
            FileItem(
                name: "remote.txt",
                location: .remote(hostID: UUID(), path: "/home/maf/remote.txt"),
                isDirectory: false,
                size: 12,
                dateModified: Date(),
                icon: NSImage()
            ),
        ]
        viewController.tableView.reloadData()
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let event = makeKeyEvent(characters: "\r", keyCode: 36)

        XCTAssertTrue(viewController.handleKeyDown(event))
        XCTAssertEqual(viewController.tableView.selectedRow, 0)
    }

    private func descendant(in view: NSView, accessibilityIdentifier: String) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier {
            return view
        }
        for subview in view.subviews {
            if let match = descendant(in: subview, accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }

    private func makeKeyEvent(characters: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
