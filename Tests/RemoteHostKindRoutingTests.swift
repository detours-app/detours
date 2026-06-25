import XCTest
@testable import Detours

final class RemoteHostKindRoutingTests: XCTestCase {
    func testRemoteHostKindCodableDefaultsToAbsent() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "displayName": "Legacy",
          "sshTarget": "legacy-host"
        }
        """
        let host = try JSONDecoder().decode(RemoteHost.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(host.kind)

        var windowsHost = host
        windowsHost.kind = .windows
        let roundTrip = try JSONDecoder().decode(RemoteHost.self, from: try JSONEncoder().encode(windowsHost))

        XCTAssertEqual(roundTrip.kind, .windows)
    }

    func testWindowsProbeRecognizesMarkerAndFallsBackToUnix() async {
        let windowsProbe = RemoteHostKindProbe(client: FakeProbeClient(outputs: [
            "DETOURS_WINDOWS_PROBE\tWin32NT\n",
        ]))
        let unixProbe = RemoteHostKindProbe(client: FakeProbeClient(outputs: [
            "",
        ]))
        let failedWindowsProbe = RemoteHostKindProbe(client: FakeProbeClient(outputs: [], errorsBeforeOutput: 1))
        let windowsKind = await windowsProbe.probe()
        let unixKind = await unixProbe.probe()
        let failedProbeKind = await failedWindowsProbe.probe()

        XCTAssertEqual(windowsKind, .windows)
        XCTAssertEqual(unixKind, .unix)
        XCTAssertEqual(failedProbeKind, .unix)
        XCTAssertTrue(RemoteHostKindProbe.windowsProbeCommand().contains("-EncodedCommand"))
    }

    func testStaleCachedUnixHostCanBeReclassifiedAsWindows() async {
        let probe = RemoteHostKindProbe(client: FakeProbeClient(outputs: [
            "DETOURS_WINDOWS_PROBE\tWin32NT\n",
        ]))

        let kind = await probe.resolve(cachedKind: .unix)

        XCTAssertEqual(kind, .windows)
    }

    func testCachedWindowsHostDoesNotReprobe() async {
        let probe = RemoteHostKindProbe(client: FakeProbeClient(outputs: [
            "",
        ]))

        let kind = await probe.resolve(cachedKind: .windows)

        XCTAssertEqual(kind, .windows)
    }

    func testWindowsProbeSkipsDeployAndPicksWindowsProvider() {
        let windowsRoute = RemoteConnectionRoute(kind: .windows)
        let unixRoute = RemoteConnectionRoute(kind: .unix)

        XCTAssertTrue(windowsRoute.usesWindowsProvider)
        XCTAssertFalse(windowsRoute.deploysHelper)
        XCTAssertFalse(unixRoute.usesWindowsProvider)
        XCTAssertTrue(unixRoute.deploysHelper)
    }
}

private actor FakeProbeClient: RemoteHostKindProbeClient {
    private var outputs: [String]
    private var errorsBeforeOutput: Int

    init(outputs: [String], errorsBeforeOutput: Int = 0) {
        self.outputs = outputs
        self.errorsBeforeOutput = errorsBeforeOutput
    }

    func run(_ command: String) async throws -> String {
        if errorsBeforeOutput > 0 {
            errorsBeforeOutput -= 1
            throw ServerDeployerError.commandFailed(command: command, status: 1, stderr: "failed")
        }
        guard !outputs.isEmpty else { return "" }
        return outputs.removeFirst()
    }
}
