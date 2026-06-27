import XCTest
@testable import Detours

/// A wedged ssh that ignores SIGTERM must never make `stopProcess()` block forever (that
/// deadlocked the Windows channel during the live suite). `terminatePromptly` must escalate to
/// SIGKILL and return quickly.
final class ProcessTerminationTests: XCTestCase {
    func testTerminatePromptlyKillsAProcessThatIgnoresSIGTERM() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 60"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        XCTAssertTrue(process.isRunning)

        let start = Date()
        PowerShellProcessTransport.terminatePromptly(process)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(process.isRunning, "A SIGTERM-ignoring process must be SIGKILLed, not left running")
        XCTAssertLessThan(elapsed, 3.0, "terminatePromptly must bound its wait, never block indefinitely")
    }

    func testTerminatePromptlyReturnsImmediatelyForExitedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        let start = Date()
        PowerShellProcessTransport.terminatePromptly(process)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
