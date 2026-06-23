import XCTest
@testable import Detours
@testable import detours_server

final class FindRPCCodecTests: XCTestCase {
    func testFindRequestRoundTrips() throws {
        let query = Data("ReadMe".utf8)
        let cap: Int64 = 500
        let message = RPCMessage.find(query: query, cap: cap)
        let encoded = try message.binaryEncoded()

        // Client codec round-trips to identical fields.
        XCTAssertEqual(try RPCMessage(binaryEncoded: encoded), message)

        // The server codec decodes the same bytes to the same query and cap.
        guard case .find(let serverQuery, let serverCap) = try ServerRPCMessage(binaryEncoded: encoded) else {
            return XCTFail("expected a find message on the server side")
        }
        XCTAssertEqual(serverQuery, query)
        XCTAssertEqual(serverCap, cap)
    }

    func testFindResultChunkRoundTrips() throws {
        let invalidUTF8 = Data([0x66, 0x6f, 0x80, 0xff])
        let nonUTF8Path = Data("/tmp/".utf8) + invalidUTF8

        let clientMatches = [
            RemoteFindMatch(path: RemotePath("/home/marco/readme.txt"), isDirectory: false),
            RemoteFindMatch(path: RemotePath("/opt/app"), isDirectory: true),
            RemoteFindMatch(path: RemotePath(bytes: nonUTF8Path), isDirectory: false),
        ]
        let clientEncoded = RemoteFindCodec.encode(clientMatches)
        XCTAssertEqual(try RemoteFindCodec.decode(clientEncoded), clientMatches)

        // The server encoder must produce byte-identical output the client can decode.
        let serverMatches = [
            FindOperations.Match(path: ServerRemotePath("/home/marco/readme.txt"), isDirectory: false),
            FindOperations.Match(path: ServerRemotePath("/opt/app"), isDirectory: true),
            FindOperations.Match(path: ServerRemotePath(bytes: nonUTF8Path), isDirectory: false),
        ]
        let serverEncoded = FindOperations.encode(serverMatches)
        XCTAssertEqual(serverEncoded, clientEncoded)
        XCTAssertEqual(try RemoteFindCodec.decode(serverEncoded), clientMatches)
    }
}
