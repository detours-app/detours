import XCTest
@testable import Detours

final class WindowsWatchChannelTests: XCTestCase {
    func testWatchDispatchesEventsAndStopsWhenUnwatched() async throws {
        let hostID = UUID()
        let transport = FakeWindowsWatchTransport()
        let channel = WindowsWatchChannel(hostID: hostID, transportFactory: SingleTransportVendor(transport).factory)
        let recorder = WatchLocationRecorder()
        let eventReceived = expectation(description: "watch event received")

        let watch = try await channel.watch(
            .remote(hostID: hostID, path: "/C:/Users/sans/watched"),
            nativePath: #"C:\Users\sans\watched"#
        ) { location in
            Task {
                await recorder.record(location)
                eventReceived.fulfill()
            }
        }

        try await transport.emitEvent(path: #"C:\Users\sans\watched\new.txt"#)
        await fulfillment(of: [eventReceived], timeout: 1.0)
        await channel.unwatch(watch)

        let requests = await transport.requests
        let locations = await recorder.locations
        let stopCount = await transport.stopCount

        XCTAssertEqual(requests.map(\.command), ["watch"])
        XCTAssertEqual(requests[0].path, #"C:\Users\sans\watched"#)
        XCTAssertEqual(locations, [.remote(hostID: hostID, path: "/C:/Users/sans/watched/new.txt")])
        XCTAssertEqual(stopCount, 1)
    }

    func testTwoConcurrentWatchesBothReceiveEvents() async throws {
        let hostID = UUID()
        let first = FakeWindowsWatchTransport()
        let second = FakeWindowsWatchTransport()
        let channel = WindowsWatchChannel(
            hostID: hostID,
            transportFactory: ListTransportVendor([first, second]).factory
        )
        let recorder = WatchLocationRecorder()

        let watchA = try await channel.watch(.remote(hostID: hostID, path: "/C:/a"), nativePath: #"C:\a"#) { loc in
            Task { await recorder.record(loc) }
        }
        let watchB = try await channel.watch(.remote(hostID: hostID, path: "/C:/b"), nativePath: #"C:\b"#) { loc in
            Task { await recorder.record(loc) }
        }

        try await first.emitEvent(path: #"C:\a\one.txt"#)
        try await second.emitEvent(path: #"C:\b\two.txt"#)
        try await waitUntil { await recorder.locations.count >= 2 }
        let locations = Set(await recorder.locations)
        XCTAssertTrue(locations.contains(.remote(hostID: hostID, path: "/C:/a/one.txt")))
        XCTAssertTrue(locations.contains(.remote(hostID: hostID, path: "/C:/b/two.txt")))

        // Closing one watch leaves the other delivering.
        await channel.unwatch(watchA)
        _ = watchB
        try await second.emitEvent(path: #"C:\b\three.txt"#)
        try await waitUntil { await recorder.locations.count >= 3 }
        let finalLocations = Set(await recorder.locations)
        XCTAssertTrue(finalLocations.contains(.remote(hostID: hostID, path: "/C:/b/three.txt")))
        let firstStopCount = await first.stopCount
        XCTAssertEqual(firstStopCount, 1, "the closed watch's process is stopped")
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not met within \(timeout)s")
    }

    func testIdleWatchSurvivesQuietPeriodViaKeepalive() async throws {
        let hostID = UUID()
        let transport = FakeWindowsWatchTransport()
        let channel = WindowsWatchChannel(hostID: hostID, transportFactory: SingleTransportVendor(transport).factory)
        let recorder = WatchLocationRecorder()
        let eventReceived = expectation(description: "event after quiet period")

        let watch = try await channel.watch(.remote(hostID: hostID, path: "/C:/q"), nativePath: #"C:\q"#) { loc in
            Task { await recorder.record(loc); eventReceived.fulfill() }
        }

        // A quiet period delivers only heartbeats, which keep the stream alive but never fire
        // a user callback. A later real event is still delivered.
        try await transport.emitHeartbeat()
        try await transport.emitHeartbeat()
        try await Task.sleep(nanoseconds: 100_000_000)
        let quietLocations = await recorder.locations
        XCTAssertTrue(quietLocations.isEmpty, "heartbeats must not be delivered as changes")

        try await transport.emitEvent(path: #"C:\q\late.txt"#)
        await fulfillment(of: [eventReceived], timeout: 1.0)
        let finalLocations = await recorder.locations
        XCTAssertEqual(finalLocations, [.remote(hostID: hostID, path: "/C:/q/late.txt")])
        await channel.unwatch(watch)
    }

    func testStopBeforeAwaitLeavesNoLeakedContinuation() async throws {
        let hostID = UUID()
        let transport = FakeWindowsWatchTransport()
        let channel = WindowsWatchChannel(hostID: hostID, transportFactory: SingleTransportVendor(transport).factory)

        let watch = try await channel.watch(.remote(hostID: hostID, path: "/C:/r"), nativePath: #"C:\r"#) { _ in }
        // Let the event loop park in readFrame, then race a teardown against it.
        try await Task.sleep(nanoseconds: 50_000_000)
        await channel.unwatch(watch)

        // If the parked read continuation leaked, stop() would not have resumed it. The
        // transport's stop must run exactly once and the channel must accept further work.
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
        await channel.stop()
    }
}

private actor WatchLocationRecorder {
    private(set) var locations: [Location] = []
    func record(_ location: Location) { locations.append(location) }
}

private struct FakeWindowsWatchRequest: Decodable {
    let id: UInt64
    let command: String
    let watchID: UUID?
    let path: String?
}

private final class SingleTransportVendor: @unchecked Sendable {
    private let transport: FakeWindowsWatchTransport
    init(_ transport: FakeWindowsWatchTransport) { self.transport = transport }
    var factory: @Sendable () -> any PowerShellChannelTransport { { self.transport } }
}

private final class ListTransportVendor: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FakeWindowsWatchTransport]
    private var index = 0
    init(_ transports: [FakeWindowsWatchTransport]) { self.transports = transports }
    var factory: @Sendable () -> any PowerShellChannelTransport {
        { self.lock.withLock { let t = self.transports[self.index]; self.index += 1; return t } }
    }
}

private actor FakeWindowsWatchTransport: PowerShellChannelTransport {
    private struct Response: Encodable {
        let type: String
        let id: UInt64?
        let watchID: UUID?
        let path: String?
        let error: String?
    }

    private var handler = RPCStreamHandler()
    private var queued: [Data] = []
    private var readContinuation: CheckedContinuation<Data, Error>?
    private(set) var requests: [FakeWindowsWatchRequest] = []
    private(set) var stopCount = 0

    func start(dispatcherBase64: String) async throws {}

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(FakeWindowsWatchRequest.self, from: payload)
            requests.append(request)
            try enqueue(Response(type: "ack", id: request.id, watchID: nil, path: nil, error: nil))
        }
    }

    func readFrame() async throws -> Data {
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            readContinuation = continuation
        }
    }

    func stop() async {
        stopCount += 1
        readContinuation?.resume(throwing: CancellationError())
        readContinuation = nil
        queued.removeAll()
    }

    func emitEvent(path: String) throws {
        try enqueue(Response(type: "event", id: nil, watchID: nil, path: path, error: nil))
    }

    func emitHeartbeat() throws {
        try enqueue(Response(type: "heartbeat", id: nil, watchID: nil, path: nil, error: nil))
    }

    private func enqueue(_ response: Response) throws {
        let data = try JSONEncoder.detoursWindows.encode(response)
        if let continuation = readContinuation {
            readContinuation = nil
            continuation.resume(returning: data)
        } else {
            queued.append(data)
        }
    }
}
