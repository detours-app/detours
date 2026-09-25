import Darwin
import XCTest
@testable import Detours

final class PowerShellFrameWriterTests: XCTestCase {
    func testBlockedReaderTimesOutAndRestoresDescriptorFlags() throws {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try PowerShellProcessTransport.writeFramePayload(Data(repeating: 42, count: 1_048_576),
                to: pipe.fileHandleForWriting, timeoutMilliseconds: 50)
            XCTFail("A full pipe must time out")
        } catch {
            guard case PowerShellChannelError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertEqual(fcntl(descriptor, F_GETFL), flags)
    }

    func testLargeFrameSurvivesPartialWrites() async throws {
        let pipe = Pipe()
        let expected = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
        let reader = Task.detached { try pipe.fileHandleForReading.readToEnd() }
        try PowerShellProcessTransport.writeFramePayload(expected, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let received = try await reader.value
        XCTAssertEqual(received, expected)
    }

    func testClosedReaderFailsWithoutSignalTermination() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try PowerShellProcessTransport.writeFramePayload(Data([1]), to: pipe.fileHandleForWriting))
    }
}
