import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class WindowsHostSessionTests: XCTestCase {
    func testActiveReaderSurvivesPaneClosureAndReleasesAfterCancellation() async throws {
        let entered = expectation(description: "Reader waiting for reply")
        let transport = SessionPowerShellTransport(holdOperation: "List", onRead: { entered.fulfill() })
        let channel = PowerShellChannel(transport: transport)
        let session = RemoteHostSession(transport: WindowsHostSessionTransport(channel: channel), idleGrace: .milliseconds(20), publish: { _, _ in })
        await channel.bind(session: session)
        let pane = try await session.acquireLifetime(.pane)
        let read = Task { try await channel.run(PowerShellScript(source: "$true"), operation: "List") }
        await fulfillment(of: [entered], timeout: 1)
        await pane.releaseAndWait()
        try await Task.sleep(for: .milliseconds(60))
        let state = await session.state
        guard case .ready = state else {
            read.cancel()
            await transport.releaseRead()
            await session.disconnect()
            return XCTFail("Final pane closure disconnected an active reader")
        }
        read.cancel()
        await transport.releaseRead()
        do { _ = try await read.value; XCTFail("Cancelled reader returned success") } catch is CancellationError {}
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await session.state != .disconnected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let final = await session.state
        XCTAssertEqual(final, .disconnected)
        await session.disconnect()
    }

    func testProviderRequestWaitsForActualOperationHandshake() async throws {
        let transport = SessionPowerShellTransport()
        let channel = PowerShellChannel(transport: transport)
        let session = RemoteHostSession(transport: WindowsHostSessionTransport(channel: channel), publish: { _, _ in })
        await channel.bind(session: session)
        let reply = try await channel.run(PowerShellScript(source: "$true"), operation: "List")
        XCTAssertEqual(String(data: reply, encoding: .utf8), "true")
        let sent = await transport.operations
        XCTAssertEqual(sent, ["OperationHandshake", "List"])
        let state = await session.state
        guard case .ready = state else { return XCTFail("Compatible operation handshake did not become ready") }
        await session.disconnect()
    }

    func testIncompatibleHostNeverReceivesProviderRequest() async throws {
        let transport = SessionPowerShellTransport(compatible: false)
        let channel = PowerShellChannel(transport: transport)
        let session = RemoteHostSession(transport: WindowsHostSessionTransport(channel: channel), publish: { _, _ in })
        await channel.bind(session: session)
        do {
            _ = try await channel.run(PowerShellScript(source: "$true"), operation: "List")
            XCTFail("Incompatible host accepted a provider request")
        } catch RemoteHostSessionError.failed(.compatibility(_)) {}
        let sent = await transport.operations
        XCTAssertEqual(sent, ["OperationHandshake"])
        await session.disconnect()
    }

    func testLostMutationReplyIsNotResentByManagedChannel() async throws {
        let transport = SessionPowerShellTransport(dropOperation: "AcceptedOperation")
        let channel = PowerShellChannel(transport: transport)
        let session = RemoteHostSession(transport: WindowsHostSessionTransport(channel: channel), publish: { _, _ in })
        await channel.bind(session: session)
        do {
            _ = try await channel.run(PowerShellScript(source: "$true"), operation: "AcceptedOperation")
            XCTFail("Lost reply returned success")
        } catch PowerShellChannelError.unexpectedEOF {}
        await session.disconnect()
        let sent = await transport.operations
        XCTAssertEqual(sent, ["OperationHandshake", "AcceptedOperation"])
    }
}

private actor SessionPowerShellTransport: PowerShellChannelTransport {
    private let compatible: Bool
    private let dropOperation: String?
    private let epoch = UUID()
    private var id: UInt64 = 0
    private var operation = ""
    private let holdOperation: String?
    private let onRead: @Sendable () -> Void
    private var heldRead: CheckedContinuation<Void, Never>?
    private(set) var operations: [String] = []

    init(compatible: Bool = true, dropOperation: String? = nil, holdOperation: String? = nil, onRead: @escaping @Sendable () -> Void = {}) {
        self.compatible = compatible
        self.dropOperation = dropOperation
        self.holdOperation = holdOperation
        self.onRead = onRead
    }

    func releaseRead() {
        heldRead?.resume()
        heldRead = nil
    }

    func start(dispatcherBase64: String) async throws {}
    func stop() async {}

    func sendFrame(_ frame: Data) async throws {
        struct Request: Decodable { let id: UInt64; let operation: String }
        let request = try JSONDecoder().decode(Request.self, from: frame.dropFirst(4))
        id = request.id
        operation = request.operation
        operations.append(operation)
    }

    func readFrame() async throws -> Data {
        if operation == holdOperation {
            await withCheckedContinuation { heldRead = $0; onRead() }
        }
        if operation == dropOperation { throw PowerShellChannelError.unexpectedEOF }
        let result: String
        if operation == "OperationHandshake" {
            let reply: OperationReply = compatible ? .handshake(.init(version: 2, schemaVersion: 1,
                capabilities: Set(OperationCapability.allCases), account: .init(hostIdentity: "windows", accountIdentity: "user"), epoch: epoch))
                : .incompatible(.protocolVersion(expected: 2, actual: 1))
            result = try XCTUnwrap(String(data: reply.encoded(), encoding: .utf8))
        } else { result = "true" }
        struct Response: Encodable { let id: UInt64; let ok: Bool; let resultJSON: String }
        return try JSONEncoder().encode(Response(id: id, ok: true, resultJSON: result))
    }
}
