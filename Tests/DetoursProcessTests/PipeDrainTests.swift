import Foundation
import XCTest
@testable import DetoursProcess

final class PipeDrainTests: XCTestCase {
    func testDrainConsumesMoreThanPipeCapacityBeforeWriterCloses() throws {
        let pipe = Pipe()
        let payload = Data(repeating: 0x45, count: 2 * 1_024 * 1_024)
        let drain = PipeDrain.start(reading: pipe.fileHandleForReading)
        let writer = pipe.fileHandleForWriting
        let thread = Thread {
            writer.write(payload)
            try? writer.close()
        }
        thread.start()

        XCTAssertEqual(drain.wait(), payload)
    }
}
