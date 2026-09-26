import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

final class RemoteSourceProofTests: XCTestCase {
    func testFileProofBindsActualBytesToObservedIdentity() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let result = try await fixture.coordinator().lookup(fixture.intent.sources[0].path,
            hostID: fixture.hostID, proveContent: true)
        XCTAssertEqual(result.result, .found(fixture.intent.sourceObservations[0]))
        XCTAssertEqual(result.location.account, fixture.account)
        let recorded = try fixture.store.load(fixture.intent.id.operation)
        XCTAssertTrue(recorded.items.isEmpty)
        await fixture.session.disconnect()
    }

    func testTreeProofDetectsChangedChildWithoutChangingRootIdentity() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let folder = fixture.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("child")
        try Data("first".utf8).write(to: child)
        let path = OperationLocation.Path.unix(Data(folder.path.utf8))
        let coordinator = fixture.coordinator()
        guard case .found(let before) = try await coordinator.lookup(path, hostID: fixture.hostID, proveContent: true).result else {
            return XCTFail("No original tree proof")
        }
        try Data("other".utf8).write(to: child)
        guard case .found(let after) = try await coordinator.lookup(path, hostID: fixture.hostID, proveContent: true).result else {
            return XCTFail("No changed tree proof")
        }
        XCTAssertEqual(before.identity, after.identity)
        XCTAssertNotNil(before.sha256)
        XCTAssertNotEqual(before.sha256, after.sha256)
        let parent = try OperationDirectory(path: Data(fixture.root.path.utf8))
        XCTAssertEqual(after.sha256, try parent.manifest(Data("folder".utf8), progress: { _ in }).proof.sha256)
        await fixture.session.disconnect()
    }

    func testSelectedLinkProofPreservesLinkInsteadOfFollowingTarget() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing target")
        guard case .found(let proof) = try await fixture.coordinator().lookup(.unix(Data(link.path.utf8)),
            hostID: fixture.hostID, proveContent: true).result else { return XCTFail("No selected link proof") }
        XCTAssertEqual(proof.kind, .symbolicLink)
        XCTAssertEqual(proof.linkTarget, Data("missing target".utf8))
        XCTAssertNotNil(proof.sha256)
        await fixture.session.disconnect()
    }

    func testProofPreservesTypedMissingAndRejectsForeignAccount() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let path = OperationLocation.Path.unix(Data(fixture.root.appendingPathComponent("missing").path.utf8))
        let missing = try await fixture.coordinator().lookup(path, hostID: fixture.hostID, proveContent: true)
        XCTAssertEqual(missing.result, .missing)
        let foreign = OperationLocation(account: .init(hostIdentity: "other", accountIdentity: "other"), path: path)
        let rejected = try await fixture.boundary.service.reply(to: .sourceProof(foreign))
        XCTAssertEqual(rejected, .incompatible(.accountMismatch))
        await fixture.session.disconnect()
    }
}
