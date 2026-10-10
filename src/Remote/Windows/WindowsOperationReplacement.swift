import Foundation

extension WindowsOperationScripts {
    static let replacementHelpers = #"""
    function Set-WindowsBackupReference($Context, $KnownLocation, $Locations) {
        $backup = $Context.record.windowsReplacementBackup
        $reference = @{ identity = $backup.observation.identity; purpose = 'displacedOriginal'; original = $Context.record.intent.destination
            knownLocation = $KnownLocation; possibleLocations = @($Locations) }
        $receipt = New-WindowsReceipt $Context $Context.record.receipt.phase $Context.record.receipt.outcome
        $receipt.effects = @($Context.record.receipt.effects)
        $receipt.sourceDisposition = $Context.record.receipt.sourceDisposition
        $receipt.contentVerified = $Context.record.receipt.contentVerified
        $receipt.recovery = @($receipt.recovery | Where-Object { $_.purpose -ne 'displacedOriginal' }) + @($reference)
        Save-WindowsReceipt $Context $receipt | Out-Null
    }
    function Restore-WindowsReplacement($Context, [string]$Failure) {
        $backup = $Context.record.windowsReplacementBackup
        $restored = $false; $known = $null
        $effects = @($Context.record.receipt.effects)
        $destination = Get-OperationPath $Context.record.intent.destination $Context.account
        $holding = Get-OperationPath $backup.location $Context.account
        $expected = $backup.observation.identity
        $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') ''
        try {
            $held = Get-WindowsOperationLookup $holding
            $original = Get-WindowsOperationLookup $destination
            if ($held.ContainsKey('found') -and $held.found._0.identity.volume -ceq $expected.volume -and
                $held.found._0.identity.object -ceq $expected.object) {
                $known = $backup.location
                if ($original.ContainsKey('missing')) {
                    $receipt = New-WindowsReceipt $Context 'rollingBack' 'running'
                    Save-WindowsReceipt $Context $receipt | Out-Null
                    $actual = $held.found._0
                    [DetoursOperationFiles]::MoveExclusive($holding, $destination, $actual.identity.volume, $actual.identity.object, $actual.version) | Out-Null
                    $restored = $true; $known = $null
                }
            } elseif ($held.ContainsKey('missing') -and $original.ContainsKey('found') -and
                $original.found._0.identity.volume -ceq $expected.volume -and $original.found._0.identity.object -ceq $expected.object) {
                $restored = $true
            }
        } catch {
            $Failure += '; restoration: ' + $_.Exception.Message
            $known = $null
        } finally { $commit.Dispose() }
        $recovery = @($Context.record.receipt.recovery | Where-Object { $_.purpose -ne 'displacedOriginal' })
        $outcome = 'partial'
        if ($restored) {
            try {
                Remove-WindowsWorkspace $Context; $recovery = @()
                if ($effects.Count -eq 0) { $outcome = 'failedUnchanged' }
            }
            catch { $Failure += '; scratch cleanup: ' + $_.Exception.Message }
        } else {
            $recovery += @{ identity = $expected; purpose = 'displacedOriginal'; original = $Context.record.intent.destination
                knownLocation = $known; possibleLocations = @($backup.location, $Context.record.intent.destination) }
        }
        $receipt = New-WindowsReceipt $Context 'terminal' $outcome
        $receipt.effects = $effects; $receipt.recovery = $recovery; $receipt.failure = $Failure
        if ($Context.record.intent.action -in @('rename', 'move')) { $receipt.sourceDisposition = 'unknown' }
        Save-WindowsReceipt $Context $receipt
    }
    function Invoke-WindowsReplacement($Context, [string]$Kind) {
        $intent = $Context.record.intent
        if ($Kind -eq 'commit') {
            if ($Context.record.receipt.phase -ne 'readyToCommit') { throw 'Replacement payload is not ready.' }
            $prepared = $Context.record.receipt.preparedPayload
            Assert-WindowsObservation (Get-WindowsPreparedObservation $Context (Get-OperationPath $prepared.location $Context.account)) $prepared.observation
        } elseif ($Kind -eq 'execute' -and $intent.action -in @('rename', 'move')) {
            if (@($intent.sources).Count -ne 1 -or @($intent.sourceObservations).Count -ne 1) { throw 'Invalid replacement source.' }
            $source = Get-OperationPath $intent.sources[0] $Context.account
            if ($source -ieq (Get-OperationPath $intent.destination $Context.account)) { throw 'Replacement source is its destination.' }
            $sourceProof = [DetoursOperationFiles]::Observe($source)
            if ($sourceProof.kind -eq 'file') { $sourceProof = Get-WindowsContentProof $source }
            else { $sourceProof = Get-WindowsManifestObservation (Get-WindowsTreeProof $source) }
            Assert-WindowsObservation $sourceProof $intent.sourceObservations[0]
        } else { throw 'Unsupported replacement operation.' }
        $destination = Assert-WindowsDestination $Context
        $expected = $intent.conflict.replace._0
        $before = [DetoursOperationFiles]::Observe($destination)
        if ($before.kind -eq 'file') { $before = Get-WindowsContentProof $destination }
        else {
            $backupManifest = Get-WindowsTreeProof $destination
            $before = Get-WindowsManifestObservation $backupManifest
        }
        Assert-WindowsObservation $before $expected
        if ($null -eq $Context.record.workspace) { New-WindowsWorkspace $Context $destination | Out-Null }
        $holding = Join-Path $Context.record.windowsWorkspacePath 'displaced'
        $location = Get-WindowsOperationLocation $holding $Context.account
        $planned = $false
        try {
            $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') (Join-Path $Context.root ((Get-OperationKey $Context.identity.id) + '.cancel'))
            try {
                Assert-WindowsOperationActive $Context
                Assert-WindowsDestination $Context | Out-Null
                Assert-WindowsRarSources $intent $Context.account
                $Context.record | Add-Member -NotePropertyName windowsReplacementBackup -NotePropertyValue @{
                    location = $location; observation = $before; manifest = $backupManifest } -Force
                Save-WindowsWorkspace $Context
                $receipt = New-WindowsReceipt $Context 'committing' 'running'
                $receipt.plannedPaths = @($receipt.plannedPaths) + @($location, $intent.destination)
                Save-WindowsReceipt $Context $receipt | Out-Null
                Set-WindowsBackupReference $Context $null @($intent.destination, $location)
                $planned = $true
                Assert-WindowsOperationActive $Context
                $moved = [DetoursOperationFiles]::MoveExclusive($destination, $holding,
                    $before.identity.volume, $before.identity.object, $before.version)
                $Context.record.windowsReplacementBackup.observation = $moved
                Save-WindowsWorkspace $Context
                Set-WindowsBackupReference $Context $location @($location)
            } finally { $commit.Dispose() }
            if ($moved.kind -eq 'file') { $actual = Get-WindowsContentProof $holding }
            else {
                $heldManifest = Get-WindowsTreeProof $holding
                Assert-WindowsTreeMovement $backupManifest $heldManifest
                $actual = Get-WindowsManifestObservation $heldManifest
            }
            Assert-WindowsObservation $actual $moved
            if ($actual.sha256 -cne $before.sha256) { throw 'Displaced original content changed.' }
            $Context.record.windowsReplacementBackup.observation = $actual
            Save-WindowsWorkspace $Context
            $result = Commit-WindowsMutation $Context $Kind $true
            Complete-WindowsBackupHandoff $Context
        } catch {
            $failure = $_.Exception.Message
            if ($Context.record.receipt.outcome -eq 'committed') { return $Context.record.receipt }
            if (-not $planned) { throw }
            if (@($Context.record.receipt.effects).Count -gt 0) {
                Resolve-WindowsOperation $Context
                if ($Context.record.receipt.outcome -eq 'committed') { return $Context.record.receipt }
            }
            Restore-WindowsReplacement $Context $failure
        }
    }
    """#
}
