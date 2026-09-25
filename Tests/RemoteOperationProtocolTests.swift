import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

final class RemoteOperationProtocolTests: XCTestCase {
    private let account = OperationAccount(hostIdentity: "host-key", accountIdentity: "uid-501")

    func testRequestsCrossBothCodecsWithoutChangingPathBytes() throws {
        let id = OperationItemID(operation: UUID(), item: UUID())
        let identity = OperationRequestIdentity(id: id, account: account, epoch: UUID(), intentDigest: "digest")
        let location = OperationLocation(account: account, path: .unix(Data([0x2f, 0xff, 0x80])))
        let intent = OperationIntent(id: id, action: .copy, sources: [location], destination: nil,
                                     sourceObservations: [], conflict: .createNew)
        let requests: [OperationRequest] = [
            .handshake, .accept(identity: identity, intent: intent), .status(identity),
            .cancel(identity), .acknowledge(identity: identity, retainingUndo: true),
        ]
        for request in requests {
            let bytes = try RPCMessage.operation(request).binaryEncoded()
            XCTAssertEqual(try RPCMessage(binaryEncoded: bytes), .operation(request))
            guard case .operation(let decoded) = try ServerRPCMessage(binaryEncoded: bytes) else {
                return XCTFail("Helper decoded an operation request as another command.")
            }
            XCTAssertEqual(decoded, request)
            XCTAssertThrowsError(try RPCMessage(binaryEncoded: bytes + Data([0])))
            XCTAssertThrowsError(try ServerRPCMessage(binaryEncoded: bytes + Data([0])))
        }
    }

    func testHandshakeRejectsEveryIncompatibleBoundary() throws {
        let epoch = UUID()
        let all = Set(OperationCapability.allCases)
        let valid = OperationHandshake(version: 2, schemaVersion: 1, capabilities: all, account: account, epoch: epoch)
        XCTAssertNoThrow(try valid.validate(expectedAccount: account, expectedEpoch: epoch))
        XCTAssertThrowsError(try valid.validate(expectedAccount: account, expectedEpoch: UUID())) {
            XCTAssertEqual($0 as? OperationCompatibilityError, .epochChanged)
        }
        let other = OperationAccount(hostIdentity: "other", accountIdentity: account.accountIdentity)
        XCTAssertThrowsError(try valid.validate(expectedAccount: other, expectedEpoch: nil)) {
            XCTAssertEqual($0 as? OperationCompatibilityError, .accountMismatch)
        }
        let legacy = OperationHandshake(version: 1, schemaVersion: 1, capabilities: all, account: account, epoch: epoch)
        XCTAssertThrowsError(try legacy.validate(expectedAccount: nil, expectedEpoch: nil)) {
            XCTAssertEqual($0 as? OperationCompatibilityError, .protocolVersion(expected: 2, actual: 1))
        }
        let wrongSchema = OperationHandshake(version: 2, schemaVersion: 2, capabilities: all, account: account, epoch: epoch)
        XCTAssertThrowsError(try wrongSchema.validate(expectedAccount: nil, expectedEpoch: nil)) {
            XCTAssertEqual($0 as? OperationCompatibilityError, .journalSchema(expected: 1, actual: 2))
        }
        for capability in all {
            let incomplete = OperationHandshake(version: 2, schemaVersion: 1, capabilities: all.subtracting([capability]),
                                                account: account, epoch: epoch)
            XCTAssertThrowsError(try incomplete.validate(expectedAccount: nil, expectedEpoch: nil)) {
                XCTAssertEqual($0 as? OperationCompatibilityError, .missingCapabilities([capability]))
            }
        }
    }

    func testRepliesRetainReceiptsAndNamedCompatibilityErrors() throws {
        let id = OperationItemID(operation: UUID(), item: UUID())
        let identity = OperationRequestIdentity(id: id, account: account, epoch: UUID(), intentDigest: "digest")
        let receipt = OperationReceipt(id: id, account: account, epoch: identity.epoch, intentDigest: "digest",
                                       revision: 4, phase: .terminal, outcome: .unknown)
        let replies: [OperationReply] = [
            .receipt(receipt), .cancellationRecorded(identity), .acknowledged(identity),
            .incompatible(.protocolVersion(expected: 2, actual: 1)),
            .incompatible(.journalSchema(expected: 1, actual: 2)),
            .incompatible(.missingCapabilities([.nonReplacingCommit])),
            .incompatible(.accountMismatch), .incompatible(.epochChanged),
        ]
        for reply in replies { XCTAssertEqual(try OperationReply.decode(reply.encoded()), reply) }
    }

    func testHelperDoesNotAdvertiseUnimplementedCommitCapabilities() throws {
        let bytes = try RPCMessage.operation(.handshake).binaryEncoded()
        let reply = try RPCHandler().handle(message: ServerRPCMessage(binaryEncoded: bytes))
        XCTAssertEqual(try OperationReply.decode(reply), .incompatible(.missingCapabilities(Set(OperationCapability.allCases))))
    }
}
