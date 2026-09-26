import Foundation
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testActualSFTPDownloadCancellationPreservesSourceAndSentinel() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("sf-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let rootData = try await channel.run(PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursAccepted-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $root 'source.bin'), [byte[]]::new(1048576))
            $root
            """)), operation: "SFTPFixture")
        let root = try JSONDecoder().decode(String.self, from: rootData)
        do {
            try await exerciseSFTPCancellation(channel: channel, root: root, control: control)
            try await cleanup(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await cleanup(channel: channel, root: root) } catch { XCTFail("SFTP fixture cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    private func exerciseSFTPCancellation(channel: PowerShellChannel, root: String, control: URL) async throws {
        let destination = control.appendingPathComponent("download.bin")
        let sentinel = RemoteTransferChannel.partialURL(for: destination)
        let sentinelData = Data("unrelated partial suffix sentinel".utf8)
        try sentinelData.write(to: sentinel)
        let process = Process()
        let sftp = ProcessWindowsSFTPClient(sshTarget: "detours-windows", controlDirectory: control,
            hostTrust: SSHHostTrust(), powerShellChannel: channel, processFactory: { process })
        sftp.bandwidthLimitForTesting = 256
        let transfer = WindowsTransferChannel(powerShellChannel: channel, sftpClient: sftp)
        let download = Task {
            try await transfer.download(remotePath: root + "\\source.bin", expectedByteCount: 1_048_576, to: destination)
        }
        defer { download.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var observed: Int64 = 0
        while ContinuousClock.now < deadline, observed == 0 {
            let partials = try FileManager.default.contentsOfDirectory(at: control, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.lastPathComponent.hasPrefix(".detours-partial-") }
            for partial in partials {
                observed += Int64(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            if observed == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertGreaterThan(observed, 0, "Must interrupt after actual payload bytes arrive")
        XCTAssertLessThan(observed, 1_048_576, "Must interrupt before the transfer finishes")
        XCTAssertTrue(process.isRunning)
        let cancelledAt = ContinuousClock.now
        download.cancel()
        do { try await download.value; XCTFail("Cancelled SFTP download succeeded") } catch is CancellationError {}
        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(5))
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: control.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix(".detours-partial-") })
        let retry = WindowsTransferChannel(sshTarget: "detours-windows", powerShellChannel: channel, controlDirectory: control)
        try await retry.download(remotePath: root + "\\source.bin", expectedByteCount: 1_048_576, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 0, count: 1_048_576))
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
    }
}
