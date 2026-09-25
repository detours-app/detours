import Foundation

extension WindowsOperationScripts {
    static let trashHelpers = #"""
    function Get-WindowsTrashReference($Context, $KnownLocation) {
        $intent = $Context.record.intent
        @{ identity = $intent.sourceObservations[0].identity; purpose = 'sourceTrash'; original = $intent.sources[0]
           knownLocation = $KnownLocation; possibleLocations = @($intent.sources[0], $Context.record.windowsTrashLocation) }
    }
    function Remove-WindowsTrashDirectory($Context) {
        $directory = $Context.record.windowsTrashDirectory
        if ($null -eq $directory) { return }
        $path = Get-OperationPath $directory.location $Context.account
        [DetoursOperationFiles]::RemoveOwned($path, $directory.observation.identity.volume, $directory.observation.identity.object)
        $Context.record.windowsTrashDirectory = $null
        Save-WindowsWorkspace $Context
    }
    function Finish-WindowsTrashFailure($Context, [string]$Failure, [bool]$MoveAttempted) {
        $intent = $Context.record.intent
        $source = Get-OperationPath $intent.sources[0] $Context.account
        $expected = $intent.sourceObservations[0]
        $directoryRecorded = $null -ne $Context.record.windowsTrashDirectory
        $originAtFailure = Get-WindowsOperationLookup $source
        $outcome = 'failedUnchanged'; $disposition = 'unknown'; $recovery = @()
        if ($originAtFailure.ContainsKey('found') -and $originAtFailure.found._0.identity.volume -ceq $expected.identity.volume -and
            $originAtFailure.found._0.identity.object -ceq $expected.identity.object) { $disposition = 'present' }
        if ($MoveAttempted) {
            $outcome = 'unknown'; $disposition = 'unknown'
            $recovery = @(Get-WindowsTrashReference $Context $null)
            $target = Get-OperationPath $Context.record.windowsTrashLocation $Context.account
            $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') ''
            try {
                $held = Get-WindowsOperationLookup $target
                $origin = Get-WindowsOperationLookup $source
                if ($held.ContainsKey('found') -and $held.found._0.identity.volume -ceq $expected.identity.volume -and
                    $held.found._0.identity.object -ceq $expected.identity.object) {
                    if (-not $origin.ContainsKey('missing')) {
                        $outcome = 'partial'
                        $recovery = @(Get-WindowsTrashReference $Context $Context.record.windowsTrashLocation)
                    } else {
                        $receipt = New-WindowsReceipt $Context 'rollingBack' 'running'
                        $receipt.sourceDisposition = 'unknown'; $receipt.recovery = $recovery
                        Save-WindowsReceipt $Context $receipt | Out-Null
                        $actual = $held.found._0
                        [DetoursOperationFiles]::MoveExclusive($target, $source,
                            $actual.identity.volume, $actual.identity.object, $actual.version) | Out-Null
                        $outcome = 'failedUnchanged'; $disposition = 'present'; $recovery = @()
                    }
                } elseif ($held.ContainsKey('missing') -and $origin.ContainsKey('found') -and
                    $origin.found._0.identity.volume -ceq $expected.identity.volume -and $origin.found._0.identity.object -ceq $expected.identity.object) {
                    $outcome = 'failedUnchanged'; $disposition = 'present'; $recovery = @()
                }
            } catch { $Failure += '; restore: ' + $_.Exception.Message }
            finally { $commit.Dispose() }
        }
        if ($outcome -eq 'failedUnchanged' -and $null -ne $Context.record.windowsTrashDirectory) {
            $directory = $Context.record.windowsTrashDirectory
            $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') ''
            try { Remove-WindowsTrashDirectory $Context }
            catch {
                $outcome = 'partial'; $Failure += '; holding directory cleanup: ' + $_.Exception.Message
                $recovery += @{ identity = $directory.observation.identity; purpose = 'scratch'; original = $null
                    knownLocation = $null; possibleLocations = @($directory.location) }
            } finally { $commit.Dispose() }
        }
        if (-not $MoveAttempted -and $Context.record.receipt.phase -eq 'preparing' -and -not $directoryRecorded) {
            $outcome = 'unknown'
        }
        $receipt = New-WindowsReceipt $Context 'terminal' $outcome
        $receipt.sourceDisposition = $disposition; $receipt.recovery = $recovery; $receipt.failure = $Failure
        Save-WindowsReceipt $Context $receipt
    }
    function Invoke-WindowsTrash($Context) {
        $intent = $Context.record.intent
        if (@($intent.sources).Count -ne 1 -or @($intent.sourceObservations).Count -ne 1 -or
            $null -ne $intent.destination -or @($intent.conflict.PSObject.Properties.Name) -notcontains 'createNew') {
            throw 'Invalid accepted Trash operation.'
        }
        $moveAttempted = $false
        try {
            $source = Get-OperationPath $intent.sources[0] $Context.account
            $expected = $intent.sourceObservations[0]
            $before = [DetoursOperationFiles]::Observe($source)
            if ($before.kind -eq 'file') { $before = Get-WindowsContentProof $source }
            else {
                $manifest = Get-WindowsTreeProof $source
                $before = Get-WindowsManifestObservation $manifest
                $Context.record | Add-Member -NotePropertyName sourceManifest -NotePropertyValue $manifest -Force
                Save-WindowsWorkspace $Context
            }
            Assert-WindowsObservation $before $expected
            $root = Join-Path ([System.IO.Path]::GetDirectoryName($Context.root)) '.detours-trash'
            $directory = Join-Path $root ((Get-OperationKey $Context.identity.id) + '-' + [guid]::NewGuid().ToString('D'))
            $target = Join-Path $directory 'item'
            $location = Get-WindowsOperationLocation $target $Context.account
            $directoryLocation = Get-WindowsOperationLocation $directory $Context.account
            $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') (Join-Path $Context.root ((Get-OperationKey $Context.identity.id) + '.cancel'))
            try {
                Assert-WindowsOperationActive $Context
                $rootLookup = Get-WindowsOperationLookup $root
                if ($rootLookup.ContainsKey('missing')) { [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null }
                elseif (-not $rootLookup.ContainsKey('found') -or $rootLookup.found._0.kind -ne 'directory') { throw 'Private Trash root is unavailable.' }
                $receipt = New-WindowsReceipt $Context 'preparing' 'running'
                $receipt.preparedPayload = @{ location = $intent.sources[0]; observation = $before }
                $receipt.plannedPaths = @($directoryLocation, $location)
                $receipt.sourceDisposition = 'present'
                Save-WindowsReceipt $Context $receipt | Out-Null
                $created = [DetoursOperationFiles]::CreatePrivateDirectory($directory)
                $Context.record | Add-Member -NotePropertyName windowsTrashLocation -NotePropertyValue $location -Force
                $Context.record | Add-Member -NotePropertyName windowsTrashDirectory -NotePropertyValue @{
                    location = $directoryLocation; observation = $created } -Force
                Save-WindowsWorkspace $Context
                if ($created.identity.volume -cne $before.identity.volume) { throw 'Trash requires a same-volume move.' }
                $receipt = New-WindowsReceipt $Context 'committing' 'running'
                $receipt.sourceDisposition = 'unknown'; $receipt.recovery = @(Get-WindowsTrashReference $Context $null)
                Save-WindowsReceipt $Context $receipt | Out-Null
                Assert-WindowsOperationActive $Context
                $moveAttempted = $true
                $moved = [DetoursOperationFiles]::MoveExclusive($source, $target,
                    $before.identity.volume, $before.identity.object, $before.version)
                $receipt = New-WindowsReceipt $Context 'committing' 'running'
                $receipt.sourceDisposition = 'unknown'; $receipt.effects = @(@{ location = $location; observation = $moved })
                Save-WindowsReceipt $Context $receipt | Out-Null
            } finally { $commit.Dispose() }
            if ($moved.kind -eq 'file') { $actual = Get-WindowsContentProof $target }
            else {
                $after = Get-WindowsTreeProof $target
                Assert-WindowsTreeMovement $manifest $after
                $actual = Get-WindowsManifestObservation $after
            }
            Assert-WindowsObservation $actual $moved
            if ($actual.sha256 -cne $before.sha256) { throw 'Trashed source content changed.' }
            $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
            $receipt.effects = @(@{ location = $location; observation = $actual })
            $receipt.sourceDisposition = 'confirmed'; $receipt.contentVerified = $null -ne $actual.sha256
            $receipt.recovery = @(Get-WindowsTrashReference $Context $location)
            Save-WindowsReceipt $Context $receipt
        } catch {
            Finish-WindowsTrashFailure $Context $_.Exception.Message $moveAttempted
        }
    }
    """#
}
