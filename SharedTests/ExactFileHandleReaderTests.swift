import Foundation
import XCTest
@testable import DetoursProcess

final class ExactFileHandleReaderTests: XCTestCase {
    func testFragmentedPipeReadsAreReassembled() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let thread = Thread {
            writer.write(Data([0x01]))
            Thread.sleep(forTimeInterval: 0.01)
            writer.write(Data([0x02, 0x03]))
            Thread.sleep(forTimeInterval: 0.01)
            writer.write(Data([0x04, 0x05]))
            try? writer.close()
        }
        thread.start()

        let data = ExactFileHandleReader.read(5, from: pipe.fileHandleForReading)

        XCTAssertEqual(data, Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }
}
