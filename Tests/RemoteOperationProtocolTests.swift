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
            .handshake, .lookup(location), .sourceProof(location), .sourceManifest(location),
            .archiveLayout(location: location, format: "zip", password: "transient fixture secret"),
            .accept(identity: identity, intent: intent), .status(identity),
            .prepareUpload(identity: identity, contents: Data([0, 255])), .commit(identity), .execute(identity),
            .prepareCopy(identity), .prepareImportedTree(identity), .prepareArchive(identity: identity, password: "transient fixture secret"),
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
            .lookup(.missing), .lookup(.denied), .lookup(.disconnected), .lookup(.unsupported),
            .manifest(.missing), .manifest(.denied), .manifest(.disconnected), .manifest(.unsupported),
            .incompatible(.protocolVersion(expected: 2, actual: 1)),
            .incompatible(.journalSchema(expected: 1, actual: 2)),
            .incompatible(.missingCapabilities([.nonReplacingCommit])),
            .incompatible(.accountMismatch), .incompatible(.epochChanged),
        ]
        for reply in replies { XCTAssertEqual(try OperationReply.decode(reply.encoded()), reply) }
    }

    func testStreamHandshakeRetainsAcceptedIdentityAndRejectsLegacyVersion() throws {
        let identity = OperationRequestIdentity(id: .init(operation: UUID(), item: UUID()), account: account,
                                                epoch: UUID(), intentDigest: "digest")
        let handshake = OperationStreamHandshake(identity: identity)
        XCTAssertEqual(try OperationStreamHandshake.decode(handshake.encoded()), handshake)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: handshake.encoded()) as? [String: Any])
        object["version"] = 1
        XCTAssertThrowsError(try OperationStreamHandshake.decode(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? OperationCompatibilityError, .protocolVersion(expected: 2, actual: 1))
        }
    }

    func testHelperLookupReturnsBoundObjectEvidenceAndTypedAbsence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let service = try await ServerOperationService(root: root.appendingPathComponent("journal"), account: account, homeDirectory: root)
        let handler = RPCHandler(operationService: service)
        let file = root.appendingPathComponent("file")
        try Data("contents".utf8).write(to: file)
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        let expected = try directory.observe(Data("file".utf8))
        let location = OperationLocation(account: account, path: .unix(Data(file.path.utf8)))
        let response = try handler.handle(message: .operation(.lookup(location)))
        let result = try OperationReply.decode(response)
        XCTAssertEqual(result, .lookup(.found(expected)))
        XCTAssertEqual(try OperationReply.decode(result.encoded()), result)
        for name in ["missing", "missing-parent/child"] {
            let missing = OperationLocation(account: account, path: .unix(Data(root.appendingPathComponent(name).path.utf8)))
            let response = try handler.handle(message: .operation(.lookup(missing)))
            XCTAssertEqual(try OperationReply.decode(response), .lookup(.missing))
        }
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let deniedLocation = OperationLocation(account: account, path: .unix(Data(denied.appendingPathComponent("child").path.utf8)))
        let deniedResponse = try handler.handle(message: .operation(.lookup(deniedLocation)))
        XCTAssertEqual(try OperationReply.decode(deniedResponse), .lookup(.denied))
        let wrong = OperationLocation(account: .init(hostIdentity: "other", accountIdentity: "other"), path: location.path)
        let rejected = try handler.handle(message: .operation(.lookup(wrong)))
        XCTAssertEqual(try OperationReply.decode(rejected), .incompatible(.accountMismatch))
        XCTAssertEqual(try Data(contentsOf: file), Data("contents".utf8))
    }

    func testHelperNegotiatesTheJournaledOperationService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try await ServerOperationService(root: root, account: account)
        let handler = RPCHandler(operationService: service)
        let bytes = try RPCMessage.operation(.handshake).binaryEncoded()
        let reply = try handler.handle(message: ServerRPCMessage(binaryEncoded: bytes))
        guard case .handshake(let handshake) = try OperationReply.decode(reply) else { return XCTFail("Missing handshake") }
        XCTAssertNoThrow(try handshake.validate(expectedAccount: account, expectedEpoch: service.journal.epoch))
        let legacy = OperationRequest.handshake(version: 1, schemaVersion: 1, requiredCapabilities: [])
        let rejected = try handler.handle(message: .operation(legacy))
        XCTAssertEqual(try OperationReply.decode(rejected), .incompatible(.protocolVersion(expected: 2, actual: 1)))
    }
}
