import AppKit
import XCTest
import RemoteOperationSupport
@testable import detours_server
@testable import Detours

@MainActor
final class ClipboardManagerTests: XCTestCase {
    private var previousItems: [NSPasteboardItem] = []

    override func setUp() async throws {
        try await super.setUp()
        previousItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                }
            }
            return clone
        }
        ClipboardManager.shared.clear()
    }

    override func tearDown() async throws {
        NSPasteboard.general.clearContents()
        if !previousItems.isEmpty {
            NSPasteboard.general.writeObjects(previousItems)
        }
        try await super.tearDown()
    }

    func testCopyWritesToPasteboard() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.copy(items: [file])

        let items = ClipboardManager.shared.items
        XCTAssertEqual(items, [file])
    }

    func testCutSetsIsCutFlag() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.isCut)
    }

    func testCopyClearsIsCutFlag() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])
        ClipboardManager.shared.copy(items: [file])

        XCTAssertFalse(ClipboardManager.shared.isCut)
    }

    func testHasItemsTrue() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.copy(items: [file])
        XCTAssertTrue(ClipboardManager.shared.hasItems)
    }

    func testHasItemsFalse() {
        XCTAssertFalse(ClipboardManager.shared.hasItems)
    }

    func testClearResetsState() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])
        ClipboardManager.shared.clear()

        XCTAssertFalse(ClipboardManager.shared.isCut)
        XCTAssertFalse(ClipboardManager.shared.hasItems)
    }

    func testCutPopulatesCutItemURLs() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.cutItemURLs.contains(file))
    }

    func testIsItemCut() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        ClipboardManager.shared.cut(items: [file])

        XCTAssertTrue(ClipboardManager.shared.isItemCut(file))
        XCTAssertFalse(ClipboardManager.shared.isItemCut(temp))
    }

    func testCopyRemoteLocationsKeepsInternalClipboardState() {
        let location = Location.remote(hostID: UUID(), path: "/home/marco/file.txt")

        ClipboardManager.shared.copy(items: [location])

        XCTAssertEqual(ClipboardManager.shared.locations, [location])
        XCTAssertTrue(ClipboardManager.shared.hasItems)
        XCTAssertTrue(ClipboardManager.shared.hasValidLocations)
        XCTAssertTrue(ClipboardManager.shared.items.isEmpty)
        XCTAssertFalse(ClipboardManager.shared.isCut)
    }

    func testCutRemoteLocationsSetsCutFlagWithoutLocalURLs() {
        let location = Location.remote(hostID: UUID(), path: "/home/marco/file.txt")

        ClipboardManager.shared.cut(items: [location])

        XCTAssertEqual(ClipboardManager.shared.locations, [location])
        XCTAssertTrue(ClipboardManager.shared.isCut)
        XCTAssertTrue(ClipboardManager.shared.cutItemURLs.isEmpty)
    }

    func testExternalPasteboardWriteInvalidatesRemoteClipboardState() {
        let location = Location.remote(hostID: UUID(), path: "/home/marco/file.txt")
        ClipboardManager.shared.cut(items: [location])

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("external", forType: .string)

        XCTAssertFalse(ClipboardManager.shared.isCut)
        XCTAssertFalse(ClipboardManager.shared.hasItems)
        XCTAssertTrue(ClipboardManager.shared.locations.isEmpty)
    }

    func testRemoteCutLocationsRemainRetryableUntilSuccess() async throws {
        let fixture = try await CoordinatorFixture()
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        defer { queue.resetRemoteQueueStateForTesting(); fixture.cleanup() }
        let output = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let source = Location.remote(hostID: fixture.hostID, path: fixture.source.path)
        let destination = Location.remote(hostID: fixture.hostID, path: output.path)
        let moved = destination.appendingPathComponent("source")
        let boundary = CutLookupBoundary(service: fixture.boundary.service, path: output.appendingPathComponent("source"))
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { try await boundary.send($0) }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: fixture.boundary.service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { _ in endpoint }
        ClipboardManager.shared.cut(items: [source])

        do {
            _ = try await ClipboardManager.shared.paste(to: destination)
            XCTFail("Denied destination inspection must prevent the move")
        } catch {
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("source").path))
        }
        XCTAssertTrue(ClipboardManager.shared.isCut)
        XCTAssertEqual(ClipboardManager.shared.locations, [source])
        XCTAssertEqual(ClipboardManager.shared.cutItemLocations, Set([source]))
        XCTAssertFalse(queue.remoteOperationResults.values.contains { $0.items.contains { $0.outcome == .committed } })

        let result = try await ClipboardManager.shared.paste(to: destination)
        XCTAssertEqual(result, [moved])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("source")), fixture.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(ClipboardManager.shared.isCut)
        XCTAssertTrue(ClipboardManager.shared.locations.isEmpty)
        XCTAssertTrue(ClipboardManager.shared.cutItemLocations.isEmpty)
        XCTAssertTrue(queue.remoteOperationResults.values.contains { $0.items.contains { $0.outcome == .committed } })
    }
}

private actor CutLookupBoundary {
    let service: ServerOperationService
    let path: OperationLocation.Path
    private var denied = false

    init(service: ServerOperationService, path: URL) {
        self.service = service
        self.path = .unix(Data(path.path.utf8))
    }

    func send(_ request: OperationRequest) async throws -> OperationReply {
        if !denied, case .lookup(let location) = request, location.path == path {
            denied = true
            return .lookup(.denied)
        }
        return try await service.reply(to: request)
    }
}
