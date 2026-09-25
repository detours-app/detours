import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class WindowsOperationFilesystemLiveTests: XCTestCase {
    private struct Arguments: Encodable { let fixtureID: UUID }
    private struct Result: Decodable {
        let before: OperationObservation
        let moved: OperationObservation
        let collisionCode: Int
        let directoryCollisionCode: Int
        let privateDirectory: Bool
        let originalsPreserved: Bool
        let staleRejected: Bool
        let linkPreserved: Bool
        let directoryPreserved: Bool
    }

    func testNativeIdentityProofAndNonReplacingMovesOnWindows() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("f-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.proofScript),
                                         arguments: Arguments(fixtureID: UUID()))
        let data: Data
        do {
            data = try await channel.run(script, operation: "OperationFilesystemProof")
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            throw error
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        XCTAssertEqual(result.before.kind, .file)
        XCTAssertEqual(result.before.byteCount, 4)
        XCTAssertEqual(result.before.sha256, try OperationContentProof.data(Data("body".utf8)).sha256)
        XCTAssertEqual(result.moved.identity, result.before.identity)
        XCTAssertEqual(result.moved.contentVersion, result.before.contentVersion)
        XCTAssertTrue([80, 183].contains(result.collisionCode))
        XCTAssertEqual(result.directoryCollisionCode, 183)
        XCTAssertTrue(result.privateDirectory)
        XCTAssertTrue(result.originalsPreserved)
        XCTAssertTrue(result.staleRejected)
        XCTAssertTrue(result.linkPreserved)
        XCTAssertTrue(result.directoryPreserved)
    }

    private static let proofScript = #"""
    param($Arguments)
    \#(WindowsOperationScripts.filesystemHelpers)
    \#(WindowsOperationScripts.journalHelpers)
    function Get-NativeErrorCode($Exception) {
        $cause = $Exception.GetBaseException()
        if ($cause -isnot [System.ComponentModel.Win32Exception]) { throw $cause }
        $cause.NativeErrorCode
    }
    function Move-Observed($Source, $Target, $Expected) {
        [DetoursOperationFiles]::MoveExclusive($Source, $Target,
            $Expected.identity.volume, $Expected.identity.object, $Expected.version)
    }
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursFilesystem-' + [guid]$Arguments.fixtureID)
    [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
    $link = Join-Path $root 'link'
    $movedLink = Join-Path $root 'moved-link'
    try {
        $privateDirectory = (Open-OperationDirectory $root) -eq $root
        $directoryCollisionCode = 0
        try { [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null }
        catch { $directoryCollisionCode = Get-NativeErrorCode $_.Exception }
        $source = Join-Path $root 'source.txt'
        $target = Join-Path $root 'renamed space-é.txt'
        $occupied = Join-Path $root 'occupied.txt'
        [System.IO.File]::WriteAllText($source, 'body', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($occupied, 'competitor')
        $before = [DetoursOperationFiles]::Prove($source)
        $collisionCode = 0
        try { Move-Observed $source $occupied $before | Out-Null }
        catch { $collisionCode = Get-NativeErrorCode $_.Exception }
        $originalsPreserved = [System.IO.File]::ReadAllText($source) -ceq 'body' -and
            [System.IO.File]::ReadAllText($occupied) -ceq 'competitor'
        $moved = Move-Observed $source $target $before
        if ([System.IO.File]::Exists($source) -or [System.IO.File]::ReadAllText($target) -cne 'body') {
            throw 'Native move returned without moving the selected file.'
        }
        [System.IO.File]::WriteAllText($source, 'replacement')
        $unexpected = Join-Path $root 'unexpected'
        $staleRejected = $false
        try { Move-Observed $source $unexpected $before | Out-Null }
        catch { $staleRejected = $_.Exception.GetBaseException().Message -ceq 'Operation object changed.' }
        $staleRejected = $staleRejected -and -not [System.IO.File]::Exists($unexpected) -and
            [System.IO.File]::ReadAllText($source) -ceq 'replacement'

        $directory = Join-Path $root 'folder'
        $movedDirectory = Join-Path $root 'moved-folder'
        $expectedDirectory = [DetoursOperationFiles]::CreatePrivateDirectory($directory)
        [System.IO.File]::WriteAllText((Join-Path $directory 'child'), 'child')
        $expectedDirectory = [DetoursOperationFiles]::Observe($directory)
        $directoryResult = Move-Observed $directory $movedDirectory $expectedDirectory
        $directoryPreserved = $directoryResult.identity.object -ceq $expectedDirectory.identity.object -and
            [System.IO.File]::ReadAllText((Join-Path $movedDirectory 'child')) -ceq 'child'
        New-Item -ItemType Junction -Path $link -Target $movedDirectory | Out-Null
        $expectedLink = [DetoursOperationFiles]::Observe($link)
        $linkResult = Move-Observed $link $movedLink $expectedLink
        $linkPreserved = $expectedLink.kind -ceq 'symbolicLink' -and $linkResult.kind -ceq 'symbolicLink' -and
            $expectedLink.identity.object -ceq $linkResult.identity.object -and
            $expectedLink.linkTarget -ceq $linkResult.linkTarget -and
            [System.IO.File]::ReadAllText((Join-Path $movedDirectory 'child')) -ceq 'child'
        [pscustomobject]@{
            before = $before; moved = $moved; collisionCode = $collisionCode; directoryCollisionCode = $directoryCollisionCode
            privateDirectory = $privateDirectory; originalsPreserved = $originalsPreserved; staleRejected = $staleRejected
            linkPreserved = $linkPreserved; directoryPreserved = $directoryPreserved
        }
    } finally {
        foreach ($path in @($link, $movedLink)) {
            if ([System.IO.Directory]::Exists($path)) { [System.IO.Directory]::Delete($path) }
        }
        [System.IO.Directory]::Delete($root, $true)
    }
    """#
}
