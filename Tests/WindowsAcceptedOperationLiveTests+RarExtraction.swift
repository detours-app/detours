import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testAcceptedRarMatchesFixtureManifest() async throws {
        let fixture = try await RarWindowsFixture.create()
        do {
            for archive in try RarTestCorpus.load().archives where archive.expectedRefusal == nil {
                print("Windows RAR family: \(archive.id)")
                let parts = try await fixture.stage(archive, folder: archive.id)
                let selected = try XCTUnwrap(parts.last)
                if archive.password != nil {
                    let reply = try await fixture.send(.archiveLayout(location: fixture.location(selected), format: "rar", password: nil))
                    XCTAssertEqual(reply, .archivePasswordRequired)
                }
                let layout = try await fixture.layout(selected, password: archive.password)
                XCTAssertEqual(layout.rarSources, parts.map(fixture.location))
                XCTAssertEqual(layout.singleRoot, archive.rootName)
                let destination = archive.id + "/result"
                let identity = try await fixture.accept(layout, destination: destination, encrypted: archive.password != nil)
                let ready = try await fixture.receipt(.prepareArchive(identity: identity, password: archive.password))
                XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? archive.id)
                XCTAssertTrue(ready.contentVerified)
                try await fixture.assertMissing(destination)
                let committed = try await fixture.receipt(.commit(identity))
                XCTAssertEqual(committed.outcome, .committed, committed.failure ?? archive.id)
                XCTAssertEqual(committed.effects.count, 1)
                try await fixture.verify(archive, destination: destination)
                let repeated = try await fixture.send(.commit(identity))
                XCTAssertEqual(repeated, .receipt(committed))
                let after = try await fixture.layout(selected, password: archive.password)
                XCTAssertEqual(after.rarObservations, layout.rarObservations)
            }
            try await fixture.cleanup()
        } catch {
            do { try await fixture.cleanup() } catch { XCTFail("RAR fixture cleanup failed: \(error)") }
            throw error
        }
    }
}
