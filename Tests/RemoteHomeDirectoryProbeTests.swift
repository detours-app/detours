import XCTest
@testable import Detours

final class RemoteHomeDirectoryProbeTests: XCTestCase {
    func testSSHArgumentsIncludeHostTrustPolicy() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let knownHosts = temp.appendingPathComponent("known_hosts")
        let probe = RemoteHomeDirectoryProbe(
            sshTarget: "wraith",
            hostTrust: SSHHostTrust(knownHostsURL: knownHosts)
        )

        let arguments = probe.arguments()

        XCTAssertEqual(arguments.prefix(4), ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"])
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("UserKnownHostsFile=\(knownHosts.path)"))
        XCTAssertTrue(arguments.contains("NumberOfPasswordPrompts=0"))
        XCTAssertEqual(arguments.suffix(2), ["wraith", "printf %s \"$HOME\""])
    }

    func testParseRejectsEmptyHomeDirectory() throws {
        let probe = RemoteHomeDirectoryProbe(sshTarget: "wraith")

        XCTAssertThrowsError(
            try probe.parse(
                terminationStatus: 0,
                stdout: Data(" \n".utf8),
                stderr: Data()
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("home directory"))
        }
    }

    func testParseUsesStderrOnFailure() throws {
        let probe = RemoteHomeDirectoryProbe(sshTarget: "wraith")

        XCTAssertThrowsError(
            try probe.parse(
                terminationStatus: 255,
                stdout: Data(),
                stderr: Data("permission denied\n".utf8)
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("permission denied"))
        }
    }
}
