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

final class IdleHostProbeTests: XCTestCase {
    func testOnlySessionlessHostsWithHistoryOrFailureAreProbed() {
        // Green-from-history and red-from-failure dots are unverified claims: probe.
        XCTAssertTrue(MainSplitViewController.idleProbeCandidate(state: nil, lastConnected: Date()))
        XCTAssertTrue(MainSplitViewController.idleProbeCandidate(
            state: .failed(reason: .transport("down")), lastConnected: Date()
        ))
        // Never-connected hosts show a neutral dot; a live or in-flight session
        // reports its own state: leave all of those alone.
        XCTAssertFalse(MainSplitViewController.idleProbeCandidate(state: nil, lastConnected: nil))
        XCTAssertFalse(MainSplitViewController.idleProbeCandidate(state: .connected, lastConnected: Date()))
        XCTAssertFalse(MainSplitViewController.idleProbeCandidate(state: .connecting, lastConnected: Date()))
    }

    func testProbeResultOnlyFlipsUnverifiedStates() {
        // Unreachable idle host goes red.
        XCTAssertEqual(
            MainSplitViewController.idleProbeResultState(reachable: false, currentState: nil),
            .failed(reason: .transport("Host is not reachable."))
        )
        // A host that came back clears its earlier failure so the dot recovers.
        XCTAssertEqual(
            MainSplitViewController.idleProbeResultState(
                reachable: true, currentState: .failed(reason: .transport("down"))
            ),
            .disconnected
        )
        // Reachable idle host stays as it is; a session started mid-probe wins.
        XCTAssertNil(MainSplitViewController.idleProbeResultState(reachable: true, currentState: nil))
        XCTAssertNil(MainSplitViewController.idleProbeResultState(reachable: false, currentState: .connecting))
        XCTAssertNil(MainSplitViewController.idleProbeResultState(reachable: false, currentState: .connected))
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
