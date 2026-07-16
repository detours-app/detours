import DetoursProcess
import Foundation
import XCTest

final class PtyProcessRunnerTests: XCTestCase {
    func testRunsWithoutPasswordAndCapturesOutput() throws {
        let result = try PtyProcessRunner().run(shell("printf runner-ok; exit 7"))

        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.outputString.contains("runner-ok"))
    }

    func testChildHasControllingTerminal() throws {
        let result = try PtyProcessRunner().run(shell(
            "test -t 0 && test -t 1 && test -t 2 && exec 3<>/dev/tty && printf tty-ok >&3 && printf child-ok"
        ))

        XCTAssertEqual(result.status, 0, result.outputString)
        XCTAssertTrue(result.outputString.contains("tty-ok"))
        XCTAssertTrue(result.outputString.contains("child-ok"))
    }

    func testFeedsOnePromptWithoutEchoingPassword() throws {
        let received = temporaryFile()
        defer { try? FileManager.default.removeItem(at: received.deletingLastPathComponent()) }
        let password = "split-secret"
        let streamed = LockedBox(Data())
        let script = """
        stty -echo
        printf 'PaSs'
        sleep 0.05
        printf 'WoRd:'
        IFS= read -r value
        stty echo
        printf '%s' "$value" > "$1"
        printf '\nreceived=%s\n' "${#value}"
        """
        let result = try PtyProcessRunner().run(
            shell(script, arguments: [received.path], password: password, responses: [.password])
        ) { data in
            streamed.withValue { $0.append(data) }
        }

        XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), password)
        XCTAssertFalse(result.outputString.contains(password))
        XCTAssertFalse((String(data: streamed.value, encoding: .utf8) ?? "").contains(password))
    }

    func testCanDisableEchoForToolThatLeavesItEnabled() throws {
        let received = temporaryFile()
        defer { try? FileManager.default.removeItem(at: received.deletingLastPathComponent()) }
        let password = "runner-disabled-echo"
        let invocation = PtyProcessInvocation(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf 'Enter password:'; IFS= read -r value; printf '%s' \"$value\" > \"$1\"",
                "detours-pty-test",
                received.path,
            ],
            password: password,
            responses: [.password],
            passwordEchoPolicy: .disableBeforeResponse
        )

        let result = try PtyProcessRunner().run(invocation)

        XCTAssertEqual(result.status, 0, result.outputString)
        XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), password)
        XCTAssertFalse(result.outputString.contains(password))
    }

    func testFeedsTwoPromptsWithoutEchoingPassword() throws {
        let received = temporaryFile()
        defer { try? FileManager.default.removeItem(at: received.deletingLastPathComponent()) }
        let password = "twice-secret"
        let script = """
        printf 'Status:'
        stty -echo
        printf 'Enter pass'
        sleep 0.05
        printf 'word:'
        IFS= read -r first
        printf 'Confirm password:'
        IFS= read -r second
        stty echo
        printf '%s\n%s' "$first" "$second" > "$1"
        """
        let result = try PtyProcessRunner().run(
            shell(script, arguments: [received.path], password: password, responses: [.password, .password])
        )

        XCTAssertEqual(result.status, 0, result.outputString)
        XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), "\(password)\n\(password)")
        XCTAssertFalse(result.outputString.contains(password))
    }

    func testEmptyRetryResponseEndsRepeatedPrompt() throws {
        let received = temporaryFile()
        defer { try? FileManager.default.removeItem(at: received.deletingLastPathComponent()) }
        let password = "retry-secret"
        let script = """
        stty -echo
        printf 'Password:'
        IFS= read -r first
        printf 'Password:'
        IFS= read -r second
        stty echo
        printf '%s\n%s' "$first" "${#second}" > "$1"
        """
        let result = try PtyProcessRunner().run(
            shell(script, arguments: [received.path], password: password, responses: [.password, .empty])
        )

        XCTAssertEqual(result.status, 0, result.outputString)
        XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), "\(password)\n0")
        XCTAssertFalse(result.outputString.contains(password))
    }

    func testPromptTimeoutTerminatesAndReapsChild() throws {
        let processIDFile = temporaryFile()
        defer { try? FileManager.default.removeItem(at: processIDFile.deletingLastPathComponent()) }
        let invocation = shell(
            "printf '%s' $$ > \"$1\"; stty -echo; printf 'Token:'; sleep 30",
            arguments: [processIDFile.path],
            password: "unused",
            responses: [.password]
        )
        let started = Date()

        XCTAssertThrowsError(try PtyProcessRunner().run(invocation)) { error in
            XCTAssertEqual(
                error as? PtyProcessError,
                .promptTimedOut(tool: "sh")
            )
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 9.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 13)
        let processID = try String(contentsOf: processIDFile, encoding: .utf8)
        XCTAssertFalse(processIsRunning(processID))
    }

    func testCancellationTerminatesChildSession() async throws {
        let processIDs = temporaryFile()
        defer { try? FileManager.default.removeItem(at: processIDs.deletingLastPathComponent()) }
        let invocation = shell(
            "sleep 30 & child=$!; printf '%s %s' $$ $child > \"$1\"; wait",
            arguments: [processIDs.path]
        )
        let task = Task { try await PtyProcessRunner().run(invocation) }
        try await waitForNonEmptyFile(processIDs)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let ids = try String(contentsOf: processIDs, encoding: .utf8).split(separator: " ").map(String.init)
        XCTAssertEqual(ids.count, 2)
        for processID in ids {
            XCTAssertFalse(processIsRunning(processID), "Process \(processID) survived cancellation")
        }
    }

    func testStreamsOutputAndBoundsDiagnosticTail() async throws {
        let streamedBytes = LockedBox(0)
        let invocation = shell(
            "dd if=/dev/zero bs=1024 count=80 2>/dev/null | tr '\\000' x; sleep 0.2; printf done"
        )
        let task = Task {
            try await PtyProcessRunner().run(invocation) { data in
                streamedBytes.withValue { $0 += data.count }
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThan(streamedBytes.value, 0)
        let result = try await task.value
        XCTAssertGreaterThan(streamedBytes.value, PtyProcessRunner.diagnosticTailLimit)
        XCTAssertLessThanOrEqual(result.output.count, PtyProcessRunner.diagnosticTailLimit)
        XCTAssertTrue(result.outputString.hasSuffix("done"))
    }

    func testPasswordAbsentFromArgumentsEnvironmentAndOutput() throws {
        let password = "s p;$weird-雪"
        let script = """
        stty -echo
        printf 'Password:'
        IFS= read -r value
        stty echo
        if test -r /proc/$$/cmdline; then
          tr '\\000' '\\n' < /proc/$$/cmdline
          tr '\\000' '\\n' < /proc/$$/environ
        else
          ps eww -p $$ -o command=
        fi
        printf 'received=%s' "${#value}"
        """
        let invocation = shell(script, password: password, responses: [.password])
        let result = try PtyProcessRunner().run(invocation)

        XCTAssertEqual(result.status, 0, result.outputString)
        XCTAssertFalse(invocation.arguments.contains(where: { $0.contains(password) }))
        XCTAssertFalse(result.outputString.contains(password))
        XCTAssertTrue(result.outputString.contains("received="))
    }

    private func shell(
        _ script: String,
        arguments: [String] = [],
        password: String? = nil,
        responses: [PtyPromptResponse] = []
    ) -> PtyProcessInvocation {
        PtyProcessInvocation(
            executable: "/bin/sh",
            arguments: ["-c", script, "detours-pty-test"] + arguments,
            password: password,
            responses: responses
        )
    }

    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("value")
    }

    private func processIsRunning(_ processID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-0", processID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func waitForNonEmptyFile(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(url.path)")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storedValue) }
    }
}
