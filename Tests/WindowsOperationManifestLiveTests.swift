import Foundation
@testable import RemoteOperationSupport
import XCTest
@testable import Detours

final class WindowsOperationManifestLiveTests: XCTestCase {
    private struct Result: Decodable {
        let before: OperationManifest
        let moved: OperationManifest
        let changed: OperationManifest
    }

    func testTreeProofMatchesSharedEncodingPreservesEmptyFoldersAndDoesNotFollowJunctions() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("t-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let script = PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.proofScript))
        let data: Data
        do {
            data = try await channel.run(script, operation: "WindowsTreeProof")
            await channel.disconnect()
        } catch { await channel.disconnect(); throw error }
        let result = try JSONDecoder().decode(Result.self, from: data)
        XCTAssertEqual(result.before.entries.count, 6)
        XCTAssertEqual(result.before.proof.byteCount, 16)
        XCTAssertEqual(result.before.proof, try OperationManifest(entries: result.before.entries).proof)
        XCTAssertEqual(result.before.entries.map(\.relativePath), result.before.entries.map(\.relativePath).sorted { $0.lexicographicallyPrecedes($1) })
        XCTAssertEqual(result.before.entries.first(where: { $0.relativePath == Data("empty".utf8) })?.observation.kind, .directory)
        XCTAssertEqual(result.before.entries.first(where: { $0.relativePath == Data("link".utf8) })?.observation.kind, .symbolicLink)
        XCTAssertEqual(result.moved.proof, result.before.proof)
        XCTAssertEqual(result.moved.entries.map { $0.observation.identity }, result.before.entries.map { $0.observation.identity })
        XCTAssertEqual(result.changed.proof.byteCount, result.before.proof.byteCount)
        XCTAssertNotEqual(result.changed.proof.sha256, result.before.proof.sha256)
    }

    private static let proofScript = #"""
    \#(WindowsOperationScripts.filesystemHelpers)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursManifest-' + [guid]::NewGuid().ToString('D'))
    [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
    $tree = Join-Path $root 'tree'; $moved = Join-Path $root 'moved'; $outside = Join-Path $root 'outside'
    try {
        [DetoursOperationFiles]::CreatePrivateDirectory($tree) | Out-Null
        [DetoursOperationFiles]::CreatePrivateDirectory($outside) | Out-Null
        [DetoursOperationFiles]::CreatePrivateDirectory((Join-Path $tree 'empty')) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tree 'é space.txt'), 'body')
        [System.IO.File]::WriteAllText((Join-Path $tree '😀.txt'), 'emoji')
        [System.IO.File]::WriteAllText((Join-Path $tree ([string][char]0xE000 + '.txt')), 'private')
        [System.IO.File]::WriteAllText((Join-Path $outside 'excluded'), 'must not be counted')
        New-Item -ItemType Junction -Path (Join-Path $tree 'link') -Target $outside | Out-Null
        $before = [DetoursOperationFiles]::Manifest($tree)
        $expected = $before.entries[0].observation
        [DetoursOperationFiles]::MoveExclusive($tree, $moved, $expected.identity.volume, $expected.identity.object, $expected.version) | Out-Null
        $after = [DetoursOperationFiles]::Manifest($moved)
        [System.IO.File]::WriteAllText((Join-Path $moved 'é space.txt'), 'edit')
        @{ before = $before; moved = $after; changed = [DetoursOperationFiles]::Manifest($moved) }
    } finally {
        foreach ($link in @((Join-Path $tree 'link'), (Join-Path $moved 'link'))) {
            if ([System.IO.Directory]::Exists($link)) { [System.IO.Directory]::Delete($link) }
        }
        [System.IO.Directory]::Delete($root, $true)
    }
    """#
}
