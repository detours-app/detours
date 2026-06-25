import XCTest
@testable import Detours

final class WindowsWatchChannelTests: XCTestCase {
    func testWatchDispatchesEventsAndStopsWhenUnwatched() async throws {
        let hostID = UUID()
        let transport = FakeWindowsWatchTransport()
        let channel = WindowsWatchChannel(hostID: hostID, transport: transport)
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

        try await transport.emitEvent(watchID: watch.id, path: #"C:\Users\sans\watched\new.txt"#)
        await fulfillment(of: [eventReceived], timeout: 1.0)
        await channel.unwatch(watch)

        let requests = await transport.requests
        let locations = await recorder.locations
        let stopCount = await transport.stopCount

        XCTAssertEqual(requests.map(\.command), ["watch", "unwatch"])
        XCTAssertEqual(requests[0].path, #"C:\Users\sans\watched"#)
        XCTAssertEqual(locations, [.remote(hostID: hostID, path: "/C:/Users/sans/watched/new.txt")])
        XCTAssertEqual(stopCount, 1)
    }
}

private actor WatchLocationRecorder {
    private(set) var locations: [Location] = []

    func record(_ location: Location) {
        locations.append(location)
    }
}

private struct FakeWindowsWatchRequest: Decodable {
    let id: UInt64
    let command: String
    let watchID: UUID?
    let path: String?
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

    func emitEvent(watchID: UUID, path: String) throws {
        try enqueue(Response(type: "event", id: nil, watchID: watchID, path: path, error: nil))
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
