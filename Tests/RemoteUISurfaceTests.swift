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

    func testAddRemoteHostSuggestionsIncludePersistedHosts() {
        let originalHosts = RemoteHostStore.shared.hosts
        defer { RemoteHostStore.shared.replaceAll(originalHosts) }

        RemoteHostStore.shared.replaceAll([
            RemoteHost(displayName: "Wraith", sshTarget: "wraith"),
        ])

        let model = AddRemoteHostModel()

        XCTAssertEqual(model.suggestions.first, "wraith")
    }

    func testAddRemoteHostSuggestionKeyboardSelection() {
        let model = AddRemoteHostModel(suggestions: ["devtest", "wraith", "wraith-build"])

        model.sshTarget = "wraith"
        XCTAssertEqual(model.visibleSuggestions, ["wraith", "wraith-build"])
        XCTAssertEqual(model.selectedSuggestion, "wraith")

        model.moveSuggestionSelection(by: 1)
        XCTAssertEqual(model.selectedSuggestion, "wraith-build")

        model.moveSuggestionSelection(by: -1)
        XCTAssertEqual(model.selectedSuggestion, "wraith")

        model.selectSuggestion(model.selectedSuggestion!)
        XCTAssertEqual(model.sshTarget, "wraith")
        XCTAssertEqual(model.selectedSuggestion, "wraith")
    }

    func testAddRemoteHostExactMatchRanksBeforeEarlierPartialMatch() {
        let model = AddRemoteHostModel(suggestions: ["wraith-wifi", "wraith"])

        model.sshTarget = "wraith"

        XCTAssertEqual(model.visibleSuggestions, ["wraith", "wraith-wifi"])
        XCTAssertFalse(model.showsTypedTargetRow)
        XCTAssertEqual(model.selectedSuggestion, "wraith")
        XCTAssertEqual(model.commitTarget(), "wraith")
    }

    func testAddRemoteHostCaseInsensitiveExactMatchCommitsConfigAlias() {
        let model = AddRemoteHostModel(suggestions: ["wraith-wifi", "wraith"])

        model.sshTarget = "Wraith"

        XCTAssertEqual(model.visibleSuggestions, ["wraith", "wraith-wifi"])
        XCTAssertFalse(model.showsTypedTargetRow)
        XCTAssertEqual(model.selectedSuggestion, "wraith")
        XCTAssertEqual(model.commitTarget(), "wraith")
    }

    func testAddRemoteHostTypedTargetWinsOverPartialSuggestionUntilUserSelectsSuggestion() {
        let model = AddRemoteHostModel(suggestions: ["wraith-wifi"])

        model.sshTarget = "Wraith"

        XCTAssertEqual(model.visibleSuggestions, ["wraith-wifi"])
        XCTAssertTrue(model.showsTypedTargetRow)
        XCTAssertNil(model.selectedSuggestion)
        XCTAssertEqual(model.commitTarget(), "Wraith")

        model.moveSuggestionSelection(by: 1)

        XCTAssertEqual(model.selectedSuggestion, "wraith-wifi")
        XCTAssertEqual(model.commitTarget(), "wraith-wifi")
    }

    func testAddRemoteHostFiltersVisibleRowsForPartialTyping() {
        let model = AddRemoteHostModel(suggestions: ["github.com", "jet", "wraith-wifi", "wraith"])

        model.sshTarget = "wrait"

        XCTAssertEqual(model.visibleSuggestions, ["wraith", "wraith-wifi"])
        XCTAssertTrue(model.showsTypedTargetRow)
        XCTAssertNil(model.selectedSuggestion)
        XCTAssertFalse(model.visibleSuggestions.contains("github.com"))
        XCTAssertFalse(model.visibleSuggestions.contains("jet"))
    }

    func testAddRemoteHostRenderedRowsForPartialTyping() {
        let model = AddRemoteHostModel(suggestions: ["github.com", "jet", "wraith-wifi", "wraith"])

        model.sshTarget = "wrait"

        XCTAssertEqual(model.visibleRows.map(\.title), ["Add wrait", "wraith", "wraith-wifi"])
        XCTAssertFalse(model.visibleRows.map(\.title).contains("github.com"))
        XCTAssertFalse(model.visibleRows.map(\.title).contains("jet"))
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
