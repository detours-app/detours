import Foundation
import XCTest
@testable import Detours

final class RemoteProcessWorkerTests: XCTestCase {
    func testDrainsLargeDiagnosticsWhileReadingOutput() async throws {
        let worker = makeWorker("/usr/bin/awk 'BEGIN { for (i=0;i<40000;i++) print \"diagnostic line\" > \"/dev/stderr\"; printf \"ready\" }'")
        let result = try await worker.perform { worker in
            try worker.start()
            try worker.start()
            worker.closeInput()
            let result = try worker.readExactly(5)
            XCTAssertEqual(try worker.waitForExit(), 0)
            worker.finishDiagnostics()
            return result
        }
        XCTAssertEqual(result, Data("ready".utf8))
        XCTAssertFalse(worker.diagnostics.isEmpty)
        XCTAssertLessThanOrEqual(worker.diagnostics.utf8.count, 16_384)
        try await worker.stop()
    }

    func testCancellationReapsProcessThatIgnoresTermination() async throws {
        let worker = makeWorker("trap '' TERM; printf ready; exec /bin/sleep 30")
        let started = expectation(description: "Child started")
        let task = Task {
            try await worker.perform { worker in
                try worker.start()
                _ = try worker.readExactly(5)
                started.fulfill()
                return try worker.readExactly(1, timeout: nil)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read returned success") } catch is CancellationError {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        XCTAssertFalse(worker.process.isRunning)
        try await worker.stop()
    }

    func testCancellationStopsBlockedWriter() async throws {
        let worker = makeWorker("printf ready; exec /bin/sleep 30")
        let started = expectation(description: "Writer starting")
        let task = Task {
            try await worker.perform { worker in
                try worker.start()
                _ = try worker.readExactly(5)
                started.fulfill()
                try worker.write(Data(repeating: 7, count: 1_048_576))
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled write returned success") } catch is CancellationError {}
        XCTAssertFalse(worker.process.isRunning)
    }

    func testResponseDeadlineStopsProcessInsteadOfLeavingReader() async throws {
        let worker = makeWorker("exec /bin/sleep 30")
        do {
            _ = try await worker.perform { worker in
                try worker.start()
                return try worker.readExactly(1, timeout: .milliseconds(30))
            }
            XCTFail("Silent process returned a reply")
        } catch RemoteProcessWorkerError.timedOut {}
        XCTAssertFalse(worker.process.isRunning)
    }

    func testCancellationBeforeLaunchNeverStartsChild() async throws {
        let worker = makeWorker("exit 0")
        worker.requestStop()
        do {
            try await worker.perform { try $0.start() }
            XCTFail("Stopped worker launched a child")
        } catch is CancellationError {}
        XCTAssertFalse(worker.process.isRunning)
        try await worker.stop()
    }

    private func makeWorker(_ script: String) -> RemoteProcessWorker {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return RemoteProcessWorker(process: process)
    }
}
