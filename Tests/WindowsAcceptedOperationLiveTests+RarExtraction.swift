import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testRarVolumesAndFailuresCannotEscape() async throws {
        let fixture = try await RarWindowsFixture.create()
        do {
            let corpus = try RarTestCorpus.load()
            let multipart = try XCTUnwrap(corpus.archives.first { $0.id == "rar5-vols.part1" })
            for mutation in ["missing", "replaced", "junction"] {
                for prepared in [false, true] {
                    let folder = "\(mutation)-\(prepared)"
                    print("Windows RAR failure case: \(folder)")
                    let parts = try await fixture.stage(multipart, folder: folder)
                    let layout = try await fixture.layout(parts[2], password: nil)
                    let destination = folder + "-result"
                    let identity = try await fixture.accept(layout, destination: destination, encrypted: false)
                    if prepared {
                        let ready = try await fixture.receipt(.prepareArchive(identity: identity, password: nil))
                        XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
                    }
                    _ = try await fixture.probe("""
                        $folder = Join-Path $Arguments.root $Arguments.folder
                        $part = Join-Path $Arguments.root $Arguments.part
                        if ($Arguments.mutation -eq 'junction') {
                            [System.IO.Directory]::Move($folder, ($folder + '-saved'))
                            New-Item -ItemType Junction -Path $folder -Target ($folder + '-saved') -ErrorAction Stop | Out-Null
                        } else {
                            [System.IO.File]::Delete($part)
                            if ($Arguments.mutation -eq 'replaced') { [System.IO.File]::WriteAllText($part, 'replacement part') }
                        }
                        @{ changed = 'True' }
                        """, values: ["folder": folder, "part": parts[1], "mutation": mutation])
                    let result = try await fixture.receipt(prepared ? .commit(identity) : .prepareArchive(identity: identity, password: nil))
                    XCTAssertEqual(result.outcome, .failedUnchanged, result.failure ?? "")
                    try await fixture.assertMissing(destination)
                }
            }
            for id in ["rar5-psw", "rar5-hpsw", "encrypted-multipart-rar4"] {
                print("Windows RAR password case: \(id)")
                let archive = try XCTUnwrap(corpus.archives.first { $0.id == id })
                let parts = try await fixture.stage(archive, folder: id)
                let layout = try await fixture.layout(try XCTUnwrap(parts.last), password: archive.password)
                let identity = try await fixture.accept(layout, destination: id + "/wrong", encrypted: true)
                let secret = "windows-rar-private-wrong-password-82917"
                let result = try await fixture.receipt(.prepareArchive(identity: identity, password: secret))
                XCTAssertEqual(result.outcome, .failedUnchanged)
                XCTAssertFalse(String(describing: result).contains(secret))
                try await fixture.assertMissing(id + "/wrong")
                try await fixture.assertPrivate(secret)
            }
            let original = try Data(contentsOf: RarTestCorpus.source("rarfile/seektest.rar"))
            var hostile = try ["C:/xxx.txt", "//xx/a.txt", "file:adsxx", "../xxx.txt", "stest2.txt"].map {
                try RarTestCorpus.renameRar4(original, from: "stest1.txt", to: $0)
            }
            for archive in corpus.archives where archive.expectedRefusal != nil {
                hostile.append(try Data(contentsOf: RarTestCorpus.source(XCTUnwrap(archive.parts.first))))
            }
            hostile.append(Data(original.dropLast(100)))
            for (index, bytes) in hostile.enumerated() {
                print("Windows RAR hostile case: \(index)")
                let relative = "hostile/\(index).rar"
                try await fixture.write(relative, bytes: bytes)
                do {
                    let layout = try await fixture.layout(relative, password: nil)
                    let identity = try await fixture.accept(layout, destination: "hostile/output-\(index)", encrypted: false)
                    let result = try await fixture.receipt(.prepareArchive(identity: identity, password: nil))
                    XCTAssertEqual(result.outcome, .failedUnchanged, "Hostile RAR case \(index): \(result)")
                } catch { XCTAssertFalse(String(describing: error).isEmpty) }
                try await fixture.assertMissing("hostile/output-\(index)")
            }
            let parts = try await fixture.stage(multipart, folder: "cancel")
            print("Windows RAR cancellation case")
            let layout = try await fixture.layout(parts[2], password: nil)
            let identity = try await fixture.accept(layout, destination: "cancel-result", encrypted: false)
            let ready = try await fixture.receipt(.prepareArchive(identity: identity, password: nil))
            XCTAssertEqual(ready.phase, .readyToCommit)
            _ = try await fixture.send(.cancel(identity))
            let cancelled = try await fixture.receipt(.commit(identity))
            XCTAssertEqual(cancelled.outcome, .failedUnchanged)
            try await fixture.assertMissing("cancel-result")
            try await fixture.assertPrivate("windows-rar-private-wrong-password-82917")
            try await fixture.cleanup()
        } catch {
            do { try await fixture.cleanup() } catch { XCTFail("RAR fixture cleanup failed: \(error)") }
            throw error
        }
    }

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
