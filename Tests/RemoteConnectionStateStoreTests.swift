import XCTest
@testable import Detours

@MainActor
final class RemoteConnectionStateStoreTests: XCTestCase {
    func testSnapshotIncludesStateRecordedBeforeReaderStarts() {
        RemoteConnectionStateStore.shared.clearForTesting()
        defer { RemoteConnectionStateStore.shared.clearForTesting() }

        let hostID = UUID()

        RemoteConnectionStateStore.shared.setState(.connected, for: hostID)

        XCTAssertEqual(RemoteConnectionStateStore.shared.snapshot()[hostID], .connected)
    }

    func testDisconnectedClearsStoredStateButStillNotifies() {
        RemoteConnectionStateStore.shared.clearForTesting()
        defer { RemoteConnectionStateStore.shared.clearForTesting() }

        let hostID = UUID()
        let recorder = StateChangeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .sshConnectionStateDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let change = notification.object as? SSHConnectionStateChange,
                  change.hostID == hostID,
                  change.newState == .disconnected else {
                return
            }
            recorder.record(change)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        RemoteConnectionStateStore.shared.setState(.connected, for: hostID)
        RemoteConnectionStateStore.shared.setState(.disconnected, for: hostID)

        XCTAssertNil(RemoteConnectionStateStore.shared.snapshot()[hostID])
        let observed = recorder.observed()
        XCTAssertEqual(observed?.oldState, .connected)
        XCTAssertEqual(observed?.newState, .disconnected)
    }
}

private final class StateChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var change: SSHConnectionStateChange?

    func record(_ change: SSHConnectionStateChange) {
        lock.withLock {
            self.change = change
        }
    }

    func observed() -> SSHConnectionStateChange? {
        lock.withLock {
            change
        }
    }
}
