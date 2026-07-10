import XCTest
@testable import Detours

@MainActor
final class RemoteTrashUndoTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RemoteTrashExplainer.markDismissed()
    }

    func testRemoteRenameRejectsPathNamesBeforeProviderLookup() async throws {
        let hostID = UUID()
        let queue = FileOperationQueue.shared
        let item = Location.remote(hostID: hostID, path: "/home/marco/project/old.txt")

        for invalidName in ["../escaped.txt", "child/name.txt", "/absolute.txt", ".."] {
            do {
                _ = try await queue.rename(item: item, to: invalidName)
                XCTFail("Expected \(invalidName) to be rejected")
            } catch let error as FileProviderError {
                XCTAssertEqual(error, .unsupportedOperation("Name contains invalid characters."))
            }
        }
    }

    func testRemoteDeleteWithoutProviderFails() async throws {
        let hostID = UUID()
        let item = Location.remote(hostID: hostID, path: "/home/marco/project/file.txt")

        do {
            try await FileOperationQueue.shared.delete(items: [item])
            XCTFail("Remote delete should require a registered provider")
        } catch let error as FileProviderError {
            XCTAssertEqual(error, .unsupportedRemote(.remote(hostID: hostID, path: "/")))
        }
    }
}
