import Foundation

extension WindowsOperationScripts {
    static let backupHandoffHelpers = #"""
    function Complete-WindowsBackupHandoff($Context) {
        $backup = $Context.record.windowsReplacementBackup
        $holding = Get-OperationPath $backup.location $Context.account
        $targetLocation = $null
        try {
            $root = Join-Path ([System.IO.Path]::GetDirectoryName($Context.root)) '.detours-trash'
            $directory = Join-Path $root ((Get-OperationKey $Context.identity.id) + '-' + [guid]::NewGuid().ToString('D'))
            $target = Join-Path $directory 'item'
            $targetLocation = Get-WindowsOperationLocation $target $Context.account
            $directoryLocation = Get-WindowsOperationLocation $directory $Context.account
            $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') ''
            try {
                $rootLookup = Get-WindowsOperationLookup $root
                if ($rootLookup.ContainsKey('missing')) { [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null }
                elseif (-not $rootLookup.ContainsKey('found') -or $rootLookup.found._0.kind -ne 'directory') { throw 'Private Trash root is unavailable.' }
                $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
                $receipt.effects = @($Context.record.receipt.effects); $receipt.sourceDisposition = $Context.record.receipt.sourceDisposition
                $receipt.contentVerified = $Context.record.receipt.contentVerified
                $receipt.plannedPaths = @($receipt.plannedPaths) + @($directoryLocation, $targetLocation)
                Save-WindowsReceipt $Context $receipt | Out-Null
                $created = [DetoursOperationFiles]::CreatePrivateDirectory($directory)
                $Context.record | Add-Member -NotePropertyName windowsTrashDirectory -NotePropertyValue @{
                    location = $directoryLocation; observation = $created } -Force
                Save-WindowsWorkspace $Context
                if ($created.identity.volume -cne $backup.observation.identity.volume) { throw 'Backup Trash handoff requires a same-volume move.' }
                Set-WindowsBackupReference $Context $null @($backup.location, $targetLocation)
                $expected = $backup.observation
                $moved = [DetoursOperationFiles]::MoveExclusive($holding, $target, $expected.identity.volume, $expected.identity.object, $expected.version)
                Set-WindowsBackupReference $Context $targetLocation @($targetLocation)
            } finally { $commit.Dispose() }
            $actual = if ($moved.kind -eq 'file') { Get-WindowsContentProof $target } else { [DetoursOperationFiles]::Observe($target) }
            Assert-WindowsObservation $actual $moved
            if ($actual.sha256 -cne $expected.sha256) { throw 'Retained original changed during Trash handoff.' }
            Remove-WindowsWorkspace $Context
            $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
            $receipt.effects = @($Context.record.receipt.effects); $receipt.sourceDisposition = $Context.record.receipt.sourceDisposition
            $receipt.contentVerified = $Context.record.receipt.contentVerified
            $receipt.recovery = @($receipt.recovery | Where-Object { $_.purpose -ne 'scratch' })
            Save-WindowsReceipt $Context $receipt
        } catch {
            $failure = 'Committed; original recovery requires attention: ' + $_.Exception.Message
            $known = $null
            $locations = @($backup.location)
            if ($null -ne $targetLocation) { $locations += $targetLocation }
            foreach ($location in $locations) {
                try {
                    $lookup = Get-WindowsOperationLookup (Get-OperationPath $location $Context.account)
                    if ($lookup.ContainsKey('found') -and $lookup.found._0.identity.volume -ceq $backup.observation.identity.volume -and
                        $lookup.found._0.identity.object -ceq $backup.observation.identity.object) { $known = $location }
                } catch { $failure += '; location check: ' + $_.Exception.Message }
            }
            Set-WindowsBackupReference $Context $known $locations
            $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
            $receipt.effects = @($Context.record.receipt.effects); $receipt.sourceDisposition = $Context.record.receipt.sourceDisposition
            $receipt.contentVerified = $Context.record.receipt.contentVerified; $receipt.failure = $failure
            foreach ($reference in $receipt.recovery) { if ($reference.purpose -eq 'scratch') { $reference.knownLocation = $null } }
            Save-WindowsReceipt $Context $receipt
        }
    }
    """#
}
