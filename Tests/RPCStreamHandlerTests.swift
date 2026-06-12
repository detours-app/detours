import XCTest
@testable import Detours

final class RPCStreamHandlerTests: XCTestCase {
    func testLengthPrefixEncoding() throws {
        let payloads = [
            Data(),
            Data("small".utf8),
            Data(repeating: 0xAB, count: 1_024 * 1_024),
        ]

        for payload in payloads {
            let encoded = try RPCStreamHandler.encodeFrame(payload)
            var handler = RPCStreamHandler()
            let decoded = try handler.append(encoded)

            XCTAssertEqual(decoded, [payload])
        }
    }

    func testPartialReadReassembly() throws {
        let payload = Data("partial frame payload".utf8)
        let encoded = try RPCStreamHandler.encodeFrame(payload)
        var handler = RPCStreamHandler()
        var decoded: [Data] = []

        for byte in encoded {
            decoded.append(contentsOf: try handler.append(Data([byte])))
        }

        XCTAssertEqual(decoded, [payload])
    }

    func testOversizedFrameRejected() throws {
        let payload = Data(repeating: 0, count: 9)

        XCTAssertThrowsError(try RPCStreamHandler.encodeFrame(payload, maxFrameSize: 8)) { error in
            XCTAssertEqual(error as? RPCProtocolError, .frameTooLarge(9))
        }

        let encoded = try RPCStreamHandler.encodeFrame(payload)
        var handler = RPCStreamHandler(maxFrameSize: 8)

        XCTAssertThrowsError(try handler.append(encoded)) { error in
            XCTAssertEqual(error as? RPCProtocolError, .frameTooLarge(9))
        }
    }

    func testStreamedDirectoryChunks() {
        var assembler = RPCResponseAssembler()
        let first = RPCEnvelope(
            id: 42,
            kind: .response,
            messageType: "List",
            sequence: 0,
            isFinal: false,
            payload: Data("first".utf8)
        )
        let second = RPCEnvelope(
            id: 42,
            kind: .response,
            messageType: "List",
            sequence: 1,
            isFinal: true,
            payload: Data("second".utf8)
        )

        XCTAssertNil(assembler.receive(first))
        let assembled = assembler.receive(second)

        XCTAssertEqual(assembled?.id, 42)
        XCTAssertEqual(assembled?.chunks, [Data("first".utf8), Data("second".utf8)])
        XCTAssertEqual(assembled?.payload, Data("firstsecond".utf8))
    }

    func testOutOfOrderResponseIDs() {
        var assembler = RPCResponseAssembler()
        let id1 = RPCEnvelope(
            id: 1,
            kind: .response,
            messageType: "Stat",
            sequence: 0,
            isFinal: true,
            payload: Data("one".utf8)
        )
        let id2First = RPCEnvelope(
            id: 2,
            kind: .response,
            messageType: "List",
            sequence: 0,
            isFinal: false,
            payload: Data("two-a".utf8)
        )
        let id2Final = RPCEnvelope(
            id: 2,
            kind: .response,
            messageType: "List",
            sequence: 1,
            isFinal: true,
            payload: Data("two-b".utf8)
        )

        XCTAssertNil(assembler.receive(id2First))
        XCTAssertEqual(assembler.receive(id1)?.payload, Data("one".utf8))
        XCTAssertEqual(assembler.receive(id2Final)?.payload, Data("two-atwo-b".utf8))
    }
}
