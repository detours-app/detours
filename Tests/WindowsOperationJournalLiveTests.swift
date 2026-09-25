import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class WindowsOperationJournalLiveTests: XCTestCase {
    private struct Arguments: Encodable {
        let fixtureID: UUID
        let intent: OperationIntent
    }

    private struct Result: Decodable {
        let snapshot: OperationJournal.Snapshot
        let cancelled: Bool
        let locked: Bool
        let changedIntentRejected: Bool
        let missingRejected: Bool
        let corruptRejected: Bool
        let retainedForUndo: Bool
        let epochStable: Bool
    }

    func testWindowsJournalPersistsExcludesAndRetainsTerminalEvidence() async throws {
        let control = FileManager.default.temporaryDirectory
            .appendingPathComponent("j-" + UUID().uuidString.prefix(6), isDirectory: true)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: control) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let account = OperationAccount(hostIdentity: "journal-fixture", accountIdentity: "journal-fixture-account")
        let intent = OperationIntent(
            id: .init(operation: UUID(), item: UUID()), action: .copy,
            sources: [], destination: nil, sourceObservations: [], conflict: .createNew
        )
        let script = try PowerShellScript(
            source: PowerShellScript.prelude(operationBody: Self.proofScript),
            arguments: Arguments(fixtureID: UUID(), intent: intent)
        )
        let data: Data
        do {
            data = try await channel.run(script, operation: "OperationJournalProof")
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            throw error
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        XCTAssertEqual(result.snapshot.id, intent.id)
        XCTAssertEqual(result.snapshot.account, account)
        XCTAssertEqual(result.snapshot.receipt?.outcome, .failedUnchanged)
        XCTAssertTrue(result.snapshot.acknowledged)
        XCTAssertNil(result.snapshot.intent)
        XCTAssertEqual(result.snapshot.revision, 3)
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.locked)
        XCTAssertTrue(result.changedIntentRejected)
        XCTAssertTrue(result.missingRejected)
        XCTAssertTrue(result.corruptRejected)
        XCTAssertTrue(result.retainedForUndo)
        XCTAssertTrue(result.epochStable)
    }

    private static let proofScript = """
    param($Arguments)
    \(WindowsOperationScripts.journalHelpers)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursJournal-' + [guid]$Arguments.fixtureID)
    if ([System.IO.Directory]::Exists($root)) { throw 'Fixture already exists.' }
    $root = Open-OperationDirectory $root
    $ownership = $null
    try {
        $account = [pscustomobject]@{ hostIdentity = 'journal-fixture'; accountIdentity = 'journal-fixture-account' }
        $epoch = Open-OperationEpoch $root $account
        $epochStable = $epoch -eq (Open-OperationEpoch $root $account)
        $intent = $Arguments.intent
        $key = Get-OperationKey $intent.id
        $lockPath = Join-Path $root ($key + '.lock')
        $ownership = Lock-OperationFile $lockPath ''
        $locked = $false
        try {
            $other = [System.IO.FileStream]::new($lockPath, 'Open', 'ReadWrite', 'None')
            $other.Dispose()
        } catch [System.IO.IOException] {
            $code = $_.Exception.HResult -band 65535
            if ($code -ne 32 -and $code -ne 33) { throw }
            $locked = $true
        }
        $missingRejected = $false
        try { Read-OperationSnapshot $root $intent.id $account $epoch | Out-Null }
        catch { $missingRejected = $_.Exception.Message -like '*record missing*' }
        Accept-Operation $root $intent 'digest' $account $epoch $ownership | Out-Null
        $changedIntentRejected = $false
        try { Accept-Operation $root $intent 'changed-digest' $account $epoch $ownership | Out-Null }
        catch { $changedIntentRejected = $_.Exception.Message -like '*intent mismatch*' }
        Cancel-Operation $root $intent.id
        $cancelled = $null -ne (Read-OperationFile (Join-Path $root ($key + '.cancel')))
        $receipt = [pscustomobject]@{
            schemaVersion = 1; id = $intent.id; account = $account; epoch = $epoch; intentDigest = 'digest'
            revision = 1; phase = 'terminal'; outcome = 'failedUnchanged'; effects = @()
            sourceDisposition = 'notRequired'; contentVerified = $false; recovery = @(); children = @(); skipped = $false
        }
        Write-OperationReceipt $root $receipt $account $epoch $ownership | Out-Null
        $retainedForUndo = $false
        try { Confirm-OperationResult $root $intent.id $account $epoch $true $ownership | Out-Null }
        catch { $retainedForUndo = $_.Exception.Message -like '*outstanding*' }
        Confirm-OperationResult $root $intent.id $account $epoch $false $ownership | Out-Null
        $snapshot = Read-OperationSnapshot $root $intent.id $account $epoch
        $path = Join-Path $root ($key + '.json')
        [System.IO.File]::WriteAllText($path, 'broken')
        $corruptRejected = $false
        try { Read-OperationSnapshot $root $intent.id $account $epoch | Out-Null }
        catch { $corruptRejected = $true }
        [pscustomobject]@{
            snapshot = $snapshot; cancelled = $cancelled; locked = $locked; changedIntentRejected = $changedIntentRejected
            missingRejected = $missingRejected; corruptRejected = $corruptRejected; retainedForUndo = $retainedForUndo
            epochStable = $epochStable
        }
    } finally {
        if ($null -ne $ownership) { $ownership.Dispose() }
        [System.IO.Directory]::Delete($root, $true)
    }
    """
}
