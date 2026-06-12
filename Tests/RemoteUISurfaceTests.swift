import XCTest
@testable import Detours

@MainActor
final class RemoteUISurfaceTests: XCTestCase {
    func testAddRemoteHostModelUsesDisplayNameAndSSHTargetOnly() {
        let model = AddRemoteHostModel(suggestions: ["devtest", "prod-vm"])

        model.sshTarget = "dev"
        XCTAssertEqual(model.filteredSuggestions, ["devtest"])

        model.selectSuggestion("devtest")
        XCTAssertEqual(model.displayName, "devtest")
        XCTAssertEqual(model.sshTarget, "devtest")
        XCTAssertTrue(model.canAdd)

        let host = model.makeHost()
        XCTAssertEqual(host.displayName, "devtest")
        XCTAssertEqual(host.sshTarget, "devtest")
    }

    func testAddRemoteHostInfersTargetFromDisplayNameWhenTargetIsBlank() {
        let model = AddRemoteHostModel(suggestions: ["devtest", "wraith"])

        model.displayName = "wraith"

        XCTAssertEqual(model.filteredSuggestions, ["wraith"])
        XCTAssertTrue(model.canAdd)

        let host = model.makeHost()
        XCTAssertEqual(host.displayName, "wraith")
        XCTAssertEqual(host.sshTarget, "wraith")
    }

    func testAddRemoteHostCanUseTargetAsDefaultDisplayName() {
        let model = AddRemoteHostModel(suggestions: ["wraith"])

        model.sshTarget = "wraith"

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
}
