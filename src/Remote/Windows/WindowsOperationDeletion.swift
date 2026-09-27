import Foundation

extension WindowsOperationScripts {
    static let deletionHelpers = #"""
    function Resolve-WindowsDeletion($Context) {
        $receipt = New-WindowsReceipt $Context 'terminal' 'unknown'
        $receipt.effects = @($Context.record.receipt.effects)
        $receipt.sourceDisposition = 'unknown'
        $receipt.failure = 'Deletion worker ended before its result was recorded; remaining files were preserved.'
        foreach ($reference in $receipt.recovery) {
            $reference.knownLocation = $null
            foreach ($location in $reference.possibleLocations) {
                $lookup = Get-WindowsOperationLookup (Get-OperationPath $location $Context.account)
                if ($lookup.ContainsKey('found') -and $lookup.found._0.identity.volume -ceq $reference.identity.volume -and
                    $lookup.found._0.identity.object -ceq $reference.identity.object) { $reference.knownLocation = $location }
            }
        }
        Save-WindowsReceipt $Context $receipt | Out-Null
    }
    function Invoke-WindowsDeletion($Context) {
        $intent = $Context.record.intent
        if ($intent.action -ne 'permanentDelete' -or @($intent.sources).Count -ne 1 -or
            @($intent.sourceObservations).Count -ne 1 -or $null -ne $intent.destination) { throw 'Invalid confirmed deletion.' }
        $source = Get-OperationPath $intent.sources[0] $Context.account
        $deleted = @(); $uncertain = $false; $held = $false
        try {
            $manifest = Get-WindowsTreeProof $source
            $root = $manifest.entries[0].observation
            $observed = if ($root.kind -eq 'file') { $root } else { Get-WindowsManifestObservation $manifest }
            Assert-WindowsObservation $observed $intent.sourceObservations[0]
            $Context.record | Add-Member -NotePropertyName sourceManifest -NotePropertyValue $manifest -Force
            Save-WindowsWorkspace $Context
            New-WindowsWorkspace $Context $source | Out-Null
            $target = Join-Path $Context.record.windowsWorkspacePath 'selected'
            $location = Get-WindowsOperationLocation $target $Context.account
            $Context.record | Add-Member -NotePropertyName windowsDeletionLocation -NotePropertyValue $location -Force
            Save-WindowsWorkspace $Context
            $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') ''
            try {
                Assert-WindowsOperationActive $Context
                $receipt = New-WindowsReceipt $Context 'committing' 'running'
                $receipt.sourceDisposition = 'unknown'
                $receipt.recovery = @($receipt.recovery) + @(@{ identity = $root.identity; purpose = 'source'; original = $intent.sources[0]
                    knownLocation = $null; possibleLocations = @($intent.sources[0], $location) })
                Save-WindowsReceipt $Context $receipt | Out-Null
                $uncertain = $true
                [DetoursOperationFiles]::MoveExclusive($source, $target, $root.identity.volume, $root.identity.object, $root.version) | Out-Null
                $held = $true; $uncertain = $false
            } finally { $commit.Dispose() }
            $after = Get-WindowsTreeProof $target
            Assert-WindowsTreeMovement $manifest $after
            foreach ($reference in $Context.record.receipt.recovery) {
                if ($reference.purpose -eq 'source') { $reference.knownLocation = $location }
            }
            $entries = @($after.entries)
            for ($index = $entries.Count - 1; $index -ge 0; $index--) {
                Assert-WindowsOperationActive $Context
                $entry = $entries[$index]
                $relative = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.relativePath))
                $path = if ($relative.Length -eq 0) { $target } else { Join-Path $target $relative }
                $original = if ($relative.Length -eq 0) { $source } else { Join-Path $source $relative }
                $parent = if ($relative.Length -eq 0) { $Context.record.workspace.root.identity } else {
                    $separator = $relative.LastIndexOf('/')
                    $parentName = if ($separator -lt 0) { '' } else { $relative.Substring(0, $separator) }
                    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($parentName))
                    $matches = @($entries | Where-Object { $_.relativePath -ceq $encoded })
                    if ($matches.Count -ne 1) { throw 'Deletion parent identity is missing.' }
                    $matches[0].observation.identity
                }
                $pin = [DetoursOperationFiles]::PinDirectory([System.IO.Path]::GetDirectoryName($path), $parent.volume, $parent.object)
                try {
                    $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') ''
                    try {
                        Assert-WindowsOperationActive $Context
                        $receipt = New-WindowsReceipt $Context 'committing' 'running'
                        $receipt.effects = $deleted; $receipt.sourceDisposition = 'unknown'
                        Save-WindowsReceipt $Context $receipt | Out-Null
                        $uncertain = $true
                        $beforeDelete = [DetoursOperationFiles]::Observe($path)
                        try { Remove-WindowsConfirmedEntry $Context $path $entry.observation }
                        catch {
                            $deletionFailure = $_
                            $remaining = Get-WindowsOperationLookup $path
                            if ($remaining.ContainsKey('found')) {
                                try { Assert-WindowsObservation $remaining.found._0 $beforeDelete; $uncertain = $false } catch { $uncertain = $true }
                            }
                            throw $deletionFailure
                        }
                        $deleted += @{ location = (Get-WindowsOperationLocation $original $Context.account); observation = $entry.observation }
                        $receipt = New-WindowsReceipt $Context 'committing' 'running'
                        $receipt.effects = $deleted; $receipt.sourceDisposition = 'unknown'
                        if ($index -eq 0) {
                            $held = $false; $receipt.phase = 'terminal'; $receipt.outcome = 'committed'; $receipt.sourceDisposition = 'confirmed'
                            $receipt.recovery = @($receipt.recovery | Where-Object { $_.purpose -ne 'source' })
                        }
                        Save-WindowsReceipt $Context $receipt | Out-Null
                        $uncertain = $false
                    } finally { $commit.Dispose() }
                } finally { $pin.Dispose() }
            }
            try { Remove-WindowsWorkspace $Context }
            catch {
                $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
                $receipt.effects = $deleted; $receipt.sourceDisposition = 'confirmed'
                $receipt.failure = 'Deleted; scratch cleanup requires recovery: ' + $_.Exception.Message
                return Save-WindowsReceipt $Context $receipt
            }
            $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
            $receipt.effects = $deleted; $receipt.sourceDisposition = 'confirmed'; $receipt.recovery = @()
            Save-WindowsReceipt $Context $receipt
        } catch {
            Finish-WindowsDeletionFailure $Context $source $deleted $held $uncertain $_.Exception.Message
        }
    }
    function Remove-WindowsConfirmedEntry($Context, [string]$Path, $Expected) {
        if ($Context.record.intent.action -ne 'permanentDelete') { throw 'Deletion requires explicit accepted confirmation.' }
        [DetoursOperationFiles]::DeleteConfirmed($Path, $Expected.identity.volume, $Expected.identity.object, $Expected.kind, $Expected.version)
    }
    function Finish-WindowsDeletionFailure($Context, [string]$Source, $Deleted, [bool]$Held, [bool]$Uncertain, [string]$Failure) {
        $restored = -not $Held -and -not $Uncertain
        if ($Held) {
            $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') ''
            try {
                $target = Get-OperationPath $Context.record.windowsDeletionLocation $Context.account
                $actual = [DetoursOperationFiles]::Observe($target)
                $expected = $Context.record.sourceManifest.entries[0].observation
                if ($actual.identity.volume -cne $expected.identity.volume -or $actual.identity.object -cne $expected.identity.object) {
                    throw 'Remaining deletion source changed identity.'
                }
                if (-not (Get-WindowsOperationLookup $Source).ContainsKey('missing')) { throw 'Original name is occupied.' }
                [DetoursOperationFiles]::MoveExclusive($target, $Source, $actual.identity.volume, $actual.identity.object, $actual.version) | Out-Null
                $restored = $true
            } catch { $Failure += '; restore: ' + $_.Exception.Message }
            finally { $commit.Dispose() }
        }
        $recovery = @($Context.record.receipt.recovery)
        if ($restored) {
            $recovery = @($recovery | Where-Object { $_.purpose -ne 'source' })
            try { Remove-WindowsWorkspace $Context; $recovery = @() }
            catch { $Failure += '; cleanup: ' + $_.Exception.Message }
        }
        $outcome = if ($Uncertain) { 'unknown' } elseif (@($Deleted).Count -gt 0 -or $recovery.Count -gt 0) { 'partial' } else { 'failedUnchanged' }
        $receipt = New-WindowsReceipt $Context 'terminal' $outcome
        $receipt.effects = @($Deleted); $receipt.recovery = $recovery
        $receipt.sourceDisposition = if ($restored) { 'present' } else { 'unknown' }
        $receipt.failure = $Failure
        Save-WindowsReceipt $Context $receipt
    }
    """#
}
