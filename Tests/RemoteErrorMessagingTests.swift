import XCTest
@testable import Detours

/// A remote file-operation failure must read as "what failed, which item/host, why, next step",
/// never the generic "Operation Failed" box.
@MainActor
final class RemoteErrorMessagingTests: XCTestCase {
    func testRemoteOperationErrorNamesActionItemAndHost() {
        let underlying = PowerShellChannelError.timeout("Timed out waiting for Windows PowerShell response.")
        let error = RemoteOperationError.operation(
            action: .copy, item: "Report.pdf", host: "win-carriercall", underlying: underlying
        )
        XCTAssertEqual(error.errorDescription, "Couldn't copy \"Report.pdf\" on win-carriercall.")
        XCTAssertEqual(error.failureReason, "The Windows host stopped responding.")
        XCTAssertEqual(error.recoverySuggestion, "Open operation details and check the result before making another change.")
    }

    func testRemoteUndoErrorNamesHost() {
        let error = RemoteOperationError.undo(host: "win-carriercall", underlying: PowerShellChannelError.unexpectedEOF)
        XCTAssertEqual(error.errorDescription, "Couldn't undo the last change on win-carriercall.")
        XCTAssertEqual(error.recoverySuggestion, "Open operation details and check the result before making another change.")
    }

    func testPowerShellRemoteErrorKeepsHostMessageAsReason() {
        let error = PowerShellChannelError.remoteError("Access to the path 'C:\\secret' is denied.")
        XCTAssertEqual(error.errorDescription, "The Windows host reported an error.")
        XCTAssertEqual(error.failureReason, "Access to the path 'C:\\secret' is denied.")
        XCTAssertEqual(error.recoverySuggestion, "Check the item and your permissions on the host, then try again.")
    }

    func testFileProviderErrorIsDescriptiveAndActionable() {
        let error = FileProviderError.unsupportedRemote(.remote(hostID: UUID(), path: "/C:"))
        XCTAssertEqual(error.errorDescription, "This action isn't available on this remote host.")
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testPresentationNeverSaysOperationFailedForRemoteFailure() {
        let underlying = PowerShellChannelError.processFailed("ssh: connect to host port 22: Operation timed out")
        let wrapped = FileOperationError.unknown(
            RemoteOperationError.operation(action: .move, item: "data.bin", host: "win-carriercall", underlying: underlying)
        )
        let presentation = FileOperationQueue.errorPresentation(for: wrapped)
        XCTAssertEqual(presentation.title, "Couldn't move \"data.bin\" on win-carriercall.")
        XCTAssertFalse(presentation.title.contains("Operation Failed"))
        XCTAssertTrue(presentation.body.contains("The connection to the Windows host failed."))
        XCTAssertTrue(presentation.body.contains("check the result before making another change"))
    }

    func testPresentationDescribesPermissionDeniedWithNextStep() {
        let presentation = FileOperationQueue.errorPresentation(
            for: FileOperationError.permissionDenied(URL(fileURLWithPath: "/tmp/x.txt"))
        )
        XCTAssertTrue(presentation.title.contains("Permission denied"))
        XCTAssertFalse(presentation.title.contains("Operation Failed"))
        XCTAssertTrue(presentation.body.contains("try again"))
    }

    func testPresentationFallbackIsActionableNotOperationFailed() {
        struct Bare: Error {}
        let presentation = FileOperationQueue.errorPresentation(for: Bare())
        XCTAssertFalse(presentation.title.contains("Operation Failed"))
        XCTAssertFalse(presentation.body.isEmpty)
    }
}
