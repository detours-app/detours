import Foundation

extension WindowsOperationScripts {
    static let mutationHelpers = #"""
    function Assert-WindowsOperationActive($Context) {
        if ($null -ne (Read-OperationFile (Join-Path $Context.root ((Get-OperationKey $Context.identity.id) + '.cancel')))) {
            throw 'Operation cancelled.'
        }
    }
    function New-WindowsReceipt($Context, [string]$Phase, [string]$Outcome) {
        $previous = $Context.record.receipt
        $revision = if ($null -eq $previous) { 1 } else { [long]$previous.revision + 1 }
        [pscustomobject]@{
            schemaVersion = 1; id = $Context.identity.id; account = $Context.account; epoch = $Context.epoch
            intentDigest = $Context.identity.intentDigest; revision = $revision; phase = $Phase; outcome = $Outcome
            effects = @(); sourceDisposition = 'notRequired'; contentVerified = $false; preparedPayload = $previous.preparedPayload
            plannedPaths = $previous.plannedPaths; recovery = @($previous.recovery | Where-Object { $null -ne $_ })
            children = @(); skipped = $false; failure = $null
        }
    }
    function Save-WindowsReceipt($Context, $Receipt) {
        $Context.record = Write-OperationReceipt $Context.root $Receipt $Context.account $Context.epoch $Context.ownership
        $Receipt
    }
    function Save-WindowsWorkspace($Context) {
        Assert-OperationOwnership $Context.root $Context.identity.id $Context.ownership
        $Context.record.revision = [long]$Context.record.revision + 1
        Write-OperationFile (Join-Path $Context.root ((Get-OperationKey $Context.identity.id) + '.json')) $Context.record
    }
    function New-WindowsOwnedObject([string]$Name, $Observation) {
        [pscustomobject]@{ name = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Name))
            identity = $Observation.identity; kind = $Observation.kind }
    }
    function Assert-WindowsDestination($Context) {
        $destination = Get-OperationPath $Context.record.intent.destination $Context.account
        $lookup = Get-WindowsOperationLookup $destination
        $conflict = $Context.record.intent.conflict
        if (@($conflict.PSObject.Properties.Name) -contains 'replace') {
            if (-not $lookup.ContainsKey('found')) { throw 'Replacement destination is not confirmed present.' }
            $actual = $lookup.found._0; $expected = $conflict.replace._0
            if ($actual.identity.volume -cne $expected.identity.volume -or $actual.identity.object -cne $expected.identity.object -or
                $actual.version -cne $expected.version -or $actual.kind -cne $expected.kind -or $actual.linkTarget -cne $expected.linkTarget) {
                throw 'Approved replacement destination changed.'
            }
            return $destination
        }
        if (@($conflict.PSObject.Properties.Name) -notcontains 'createNew') { throw 'This Windows conflict action is not implemented.' }
        if (-not $lookup.ContainsKey('missing')) { throw 'Operation destination is not confirmed missing.' }
        $destination
    }
    function New-WindowsWorkspace($Context, [string]$Destination) {
        Assert-WindowsOperationActive $Context
        $name = '.detours-partial-' + [guid]::NewGuid().ToString('N')
        $path = Join-Path ([System.IO.Path]::GetDirectoryName($Destination)) $name
        $location = Get-WindowsOperationLocation $path $Context.account
        $receipt = New-WindowsReceipt $Context 'preparing' 'running'
        $receipt.plannedPaths = @($location)
        Save-WindowsReceipt $Context $receipt | Out-Null
        $observed = [DetoursOperationFiles]::CreatePrivateDirectory($path)
        $workspace = [pscustomobject]@{ id = $Context.identity.id; root = (New-WindowsOwnedObject $name $observed); objects = @() }
        $Context.record | Add-Member -NotePropertyName workspace -NotePropertyValue $workspace -Force
        $Context.record | Add-Member -NotePropertyName windowsWorkspacePath -NotePropertyValue $path -Force
        Save-WindowsWorkspace $Context
        $receipt = New-WindowsReceipt $Context 'preparing' 'running'
        $receipt.recovery = @(@{ identity = $observed.identity; purpose = 'scratch'; original = $null
            knownLocation = $location; possibleLocations = @($location) })
        Save-WindowsReceipt $Context $receipt | Out-Null
        $path
    }
    function New-WindowsPayload($Context) {
        $path = Join-Path $Context.record.windowsWorkspacePath 'payload'
        $stream = [DetoursOperationFiles]::CreateNewFile($path)
        try {
            $observed = [DetoursOperationFiles]::ObserveStream($stream)
            $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject 'payload' $observed)
            Save-WindowsWorkspace $Context
            $stream
        } catch { $stream.Dispose(); throw }
    }
    function Remove-WindowsWorkspace($Context) {
        if ($null -eq $Context.record.workspace) { return }
        $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') ''
        try { Remove-WindowsWorkspaceContents $Context } finally { $commit.Dispose() }
    }
    function Remove-WindowsWorkspaceContents($Context) {
        if ($null -eq $Context.record.workspace) { return }
        $path = [string]$Context.record.windowsWorkspacePath
        $root = [DetoursOperationFiles]::Observe($path)
        $owned = $Context.record.workspace.root.identity
        if ($root.identity.volume -cne $owned.volume -or $root.identity.object -cne $owned.object -or $root.kind -ne 'directory') {
            throw 'Operation workspace changed.'
        }
        Remove-WindowsOwnedDescendants $Context $path '' $owned
        [DetoursOperationFiles]::RemoveOwned($path, $owned.volume, $owned.object)
        $Context.record.workspace = $null
        $Context.record.windowsWorkspacePath = $null
        Save-WindowsWorkspace $Context
    }
    function Resolve-WindowsOperation($Context) {
        $previous = $Context.record.receipt
        if ($null -eq $previous -or $previous.phase -in @('terminal', 'readyToCommit', 'payloadReceived')) { return }
        if ($Context.record.intent.action -eq 'permanentDelete') { Resolve-WindowsDeletion $Context; return }
        if ($Context.record.windowsIngressReady -and -not $Context.record.windowsIngressSealing) { return }
        $receipt = New-WindowsReceipt $Context 'terminal' 'unknown'
        $receipt.effects = @($previous.effects)
        $receipt.failure = 'Operation worker ended before its result was recorded.'
        if ($previous.phase -eq 'committing' -and ($null -ne $previous.preparedPayload -or @($previous.effects).Count -eq 1)) {
            $resultLocation = if ($Context.record.intent.action -eq 'trash') { $Context.record.windowsTrashLocation } else { $Context.record.intent.destination }
            $destination = Get-OperationPath $resultLocation $Context.account
            $lookup = Get-WindowsOperationLookup $destination
            if ($lookup.ContainsKey('found')) {
                $expected = if ($null -ne $previous.preparedPayload) { $previous.preparedPayload.observation } else { $previous.effects[0].observation }
                $actual = $lookup.found._0
                try {
                    if ($null -ne $Context.record.intent.treeProof -and ($actual.kind -ne 'directory' -or
                        $Context.record.payloadManifest.proof.sha256 -cne $Context.record.intent.treeProof.sha256 -or
                        $Context.record.payloadManifest.proof.byteCount -ne $Context.record.intent.treeProof.byteCount)) {
                        throw 'Imported folder is not verified.'
                    }
                    if ($actual.kind -eq 'file') { $actual = (Get-WindowsContentProof $destination) }
                    elseif ($null -ne $expected.sha256) {
                        $manifest = Get-WindowsTreeProof $destination
                        $expectedManifest = if ($null -ne $Context.record.payloadManifest) { $Context.record.payloadManifest } else { $Context.record.sourceManifest }
                        Assert-WindowsTreeMovement $expectedManifest $manifest
                        $actual = Get-WindowsManifestObservation $manifest
                    }
                } catch {
                    $actual = $null
                    $receipt.failure += ' Result verification: ' + $_.Exception.Message
                }
                if ($actual.identity.volume -ceq $expected.identity.volume -and $actual.identity.object -ceq $expected.identity.object -and
                    $actual.kind -ceq $expected.kind -and $actual.contentVersion -ceq $expected.contentVersion -and
                    $actual.linkTarget -ceq $expected.linkTarget -and ($null -eq $expected.sha256 -or $actual.sha256 -ceq $expected.sha256)) {
                    $receipt.outcome = 'committed'; $receipt.failure = $null
                    $receipt.effects = @(@{ location = $resultLocation; observation = $actual })
                    $receipt.contentVerified = $null -ne $expected.sha256
                    if ($Context.record.intent.action -in @('move', 'rename', 'restore')) {
                        $receipt.sourceDisposition = 'confirmed'; $receipt.recovery = @($receipt.recovery | Where-Object { $_.purpose -ne 'source' })
                    }
                    if ($Context.record.intent.action -eq 'trash') {
                        $receipt.sourceDisposition = 'confirmed'; $receipt.recovery = @(Get-WindowsTrashReference $Context $resultLocation)
                    }
                }
            }
        }
        if ($receipt.outcome -eq 'unknown' -and $Context.record.intent.action -in @('move', 'rename', 'trash', 'restore')) { $receipt.sourceDisposition = 'unknown' }
        Save-WindowsReceipt $Context $receipt | Out-Null
    }
    function Prepare-WindowsPayload($Context, [string]$Kind, $Parameters) {
        $destination = Assert-WindowsDestination $Context
        $intent = $Context.record.intent
        $source = $null; $before = $null; $sourceStream = $null
        if ($Kind -eq 'prepareUpload') {
            if ($intent.action -notin @('copy', 'editorUpload') -or $null -eq $intent.payloadProof) { throw 'Invalid accepted upload.' }
            $bytes = [Convert]::FromBase64String([string]$Parameters.contents)
            if ($bytes.Length -gt 1048576) { throw 'PowerShell upload exceeds the one MiB limit.' }
            $proof = $intent.payloadProof
            $sourceStream = [System.IO.MemoryStream]::new($bytes, $false)
        } else {
            if ($intent.action -ne 'copy' -or @($intent.sources).Count -ne 1 -or @($intent.sourceObservations).Count -ne 1) { throw 'Invalid accepted copy.' }
            $source = Get-OperationPath $intent.sources[0] $Context.account
            if ($intent.sourceObservations[0].kind -ne 'file') { return Prepare-WindowsTreePayload $Context $source $destination }
            $before = (Get-WindowsContentProof $source)
            Assert-WindowsObservation $before $intent.sourceObservations[0]
            $proof = @{ byteCount = $before.byteCount; sha256 = $before.sha256 }
            $sourceStream = [System.IO.FileStream]::new($source, 'Open', 'Read', 'Read')
        }
        try {
            New-WindowsWorkspace $Context $destination | Out-Null
            $output = New-WindowsPayload $Context
            try {
                $buffer = [byte[]]::new(65536)
                while (($count = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    Assert-WindowsOperationActive $Context
                    $output.Write($buffer, 0, $count)
                }
                $output.Flush($true)
            } finally { $output.Dispose() }
        } finally { if ($null -ne $sourceStream) { $sourceStream.Dispose() } }
        $payload = Join-Path $Context.record.windowsWorkspacePath 'payload'
        if ($null -ne $source) {
            $after = (Get-WindowsContentProof $source)
            Assert-WindowsObservation $after $before
            [System.IO.File]::SetLastWriteTimeUtc($payload, [System.IO.File]::GetLastWriteTimeUtc($source))
            [System.IO.File]::SetAttributes($payload, [System.IO.File]::GetAttributes($source))
        }
        $observed = (Get-WindowsContentProof $payload)
        if ($observed.byteCount -ne $proof.byteCount -or $observed.sha256 -cne $proof.sha256) { throw 'Operation payload verification failed.' }
        Assert-WindowsOperationActive $Context
        $phase = if ($null -eq $intent.treeProof) { 'readyToCommit' } else { 'payloadReceived' }
        $receipt = New-WindowsReceipt $Context $phase 'running'
        $receipt.preparedPayload = @{ location = (Get-WindowsOperationLocation $payload $Context.account); observation = $observed }
        $receipt.contentVerified = $true
        Save-WindowsReceipt $Context $receipt
    }
    function Commit-WindowsMutation($Context, [string]$Kind, [bool]$Replacing = $false) {
        $intent = $Context.record.intent
        if ($null -ne $intent.treeProof -and ($Kind -ne 'commit' -or
            $Context.record.receipt.preparedPayload.observation.kind -ne 'directory' -or
            $Context.record.payloadManifest.proof.sha256 -cne $intent.treeProof.sha256 -or
            $Context.record.payloadManifest.proof.byteCount -ne $intent.treeProof.byteCount)) {
            throw 'Imported folder is not verified.'
        }
        if (-not $Replacing -and @($intent.conflict.PSObject.Properties.Name) -contains 'replace') {
            return Invoke-WindowsReplacement $Context $Kind
        }
        $destination = if ($Replacing) { Get-OperationPath $intent.destination $Context.account } else { Assert-WindowsDestination $Context }
        $payload = $null
        if ($Kind -eq 'commit') {
            if ($Context.record.receipt.phase -ne 'readyToCommit' -and -not $Replacing) { throw 'Operation payload is not ready to commit.' }
            $payload = $Context.record.receipt.preparedPayload
            $source = Get-OperationPath $payload.location $Context.account
            Assert-WindowsObservation (Get-WindowsPreparedObservation $Context $source) $payload.observation
            $sourceManifest = $Context.record.payloadManifest
        } elseif ($intent.action -in @('rename', 'move', 'restore')) {
            if (@($intent.sources).Count -ne 1 -or @($intent.sourceObservations).Count -ne 1) { throw 'Invalid accepted native move.' }
            $source = Get-OperationPath $intent.sources[0] $Context.account
            $observed = [DetoursOperationFiles]::Observe($source)
            if ($observed.kind -eq 'file') { $observed = (Get-WindowsContentProof $source) }
            else {
                $sourceManifest = Get-WindowsTreeProof $source
                $observed = Get-WindowsManifestObservation $sourceManifest
                $Context.record | Add-Member -NotePropertyName sourceManifest -NotePropertyValue $sourceManifest -Force
                Save-WindowsWorkspace $Context
            }
            Assert-WindowsObservation $observed $intent.sourceObservations[0]
            $payload = @{ location = $intent.sources[0]; observation = $observed }
        } elseif ($intent.action -ne 'createFolder' -or @($intent.sources).Count -ne 0) { throw 'Unsupported accepted native operation.' }
        $commit = Lock-OperationFile (Join-Path $Context.root 'commit.lock') (Join-Path $Context.root ((Get-OperationKey $Context.identity.id) + '.cancel'))
        try {
            Assert-WindowsOperationActive $Context
            if (-not $Replacing) { $destination = Assert-WindowsDestination $Context }
            elseif (-not (Get-WindowsOperationLookup $destination).ContainsKey('missing')) { throw 'Replacement destination was occupied.' }
            Assert-WindowsRarSources $intent $Context.account
            $receipt = New-WindowsReceipt $Context 'committing' 'running'
            $receipt.preparedPayload = $payload
            $receipt.plannedPaths = @($intent.destination)
            if ($intent.action -in @('rename', 'move', 'restore')) {
                $receipt.sourceDisposition = 'unknown'
                $receipt.recovery = @($receipt.recovery) + @(@{ identity = $payload.observation.identity; purpose = 'source'; original = $payload.location
                    knownLocation = $null; possibleLocations = @($payload.location, $intent.destination) })
            }
            Save-WindowsReceipt $Context $receipt | Out-Null
            if ($null -eq $payload) { $observed = [DetoursOperationFiles]::CreateDirectoryExclusive($destination) }
            else {
                $expected = $payload.observation
                $observed = [DetoursOperationFiles]::MoveExclusive($source, $destination,
                    $expected.identity.volume, $expected.identity.object, $expected.version)
            }
            $receipt = New-WindowsReceipt $Context 'committing' 'running'
            $receipt.effects = @(@{ location = $intent.destination; observation = $observed })
            if ($intent.action -in @('rename', 'move', 'restore')) { $receipt.sourceDisposition = 'unknown' }
            Save-WindowsReceipt $Context $receipt | Out-Null
        } finally { $commit.Dispose() }
        if ($observed.kind -eq 'file') {
            $verified = Get-WindowsContentProof $destination
            Assert-WindowsObservation $verified $observed
            if ($verified.sha256 -cne $payload.observation.sha256) { throw 'Published operation content changed.' }
            $observed = $verified
        } elseif ($null -ne $payload) {
            $movedManifest = Get-WindowsTreeProof $destination
            Assert-WindowsTreeMovement $sourceManifest $movedManifest
            $verified = Get-WindowsManifestObservation $movedManifest
            Assert-WindowsObservation $verified $observed
            $observed = $verified
        }
        $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
        $receipt.effects = @(@{ location = $intent.destination; observation = $observed })
        $receipt.contentVerified = $null -ne $observed.sha256
        if ($intent.action -in @('rename', 'move', 'restore')) {
            $receipt.sourceDisposition = 'confirmed'; $receipt.recovery = @($receipt.recovery | Where-Object { $_.purpose -ne 'source' })
        }
        Save-WindowsReceipt $Context $receipt | Out-Null
        if ($Replacing) { return $receipt }
        if ($null -ne $Context.record.workspace) {
            try {
                Remove-WindowsWorkspace $Context
                $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
                $receipt.effects = @($Context.record.receipt.effects); $receipt.contentVerified = $true; $receipt.recovery = @()
                Save-WindowsReceipt $Context $receipt | Out-Null
            } catch {
                $receipt = New-WindowsReceipt $Context 'terminal' 'committed'
                $receipt.effects = @($Context.record.receipt.effects); $receipt.contentVerified = $true
                $receipt.failure = 'Committed; scratch cleanup requires recovery: ' + $_.Exception.Message
                foreach ($reference in $receipt.recovery) { $reference.knownLocation = $null }
                Save-WindowsReceipt $Context $receipt | Out-Null
            }
        }
        $receipt
    }
    function Invoke-WindowsMutation($Context, [string]$Kind, $Parameters) {
        if ($Kind -notin @('prepareUpload', 'prepareCopy', 'prepareArchive', 'prepareImportedTree', 'commit', 'execute')) { throw 'Unsupported Windows operation request.' }
        if ($Context.record.receipt.phase -eq 'terminal') { return $Context.record.receipt }
        if ($Context.record.receipt.phase -eq 'readyToCommit' -and $Kind -in @('prepareUpload', 'prepareCopy', 'prepareArchive', 'prepareImportedTree')) { return $Context.record.receipt }
        if ($Context.record.receipt.phase -eq 'payloadReceived' -and $Kind -eq 'prepareUpload') { return $Context.record.receipt }
        if ($Context.record.receipt.phase -in @('preparing', 'committing')) {
            Resolve-WindowsOperation $Context
            return $Context.record.receipt
        }
        try {
            Assert-WindowsOperationActive $Context
            if ($Kind -eq 'prepareImportedTree') { return Prepare-WindowsImportedTree $Context }
            if ($Kind -in @('prepareUpload', 'prepareCopy')) { return Prepare-WindowsPayload $Context $Kind $Parameters }
            if ($Kind -eq 'prepareArchive') { return Prepare-WindowsArchive $Context $Parameters }
            if ($Kind -eq 'execute' -and $Context.record.intent.action -eq 'permanentDelete') { return Invoke-WindowsDeletion $Context }
            if ($Kind -eq 'execute' -and $Context.record.intent.action -eq 'trash') { return Invoke-WindowsTrash $Context }
            Commit-WindowsMutation $Context $Kind
        } catch {
            $failure = $_.Exception.Message
            if ($Context.record.receipt.outcome -eq 'committed') { throw }
            if ($Context.record.receipt.phase -eq 'committing') {
                Resolve-WindowsOperation $Context
                return $Context.record.receipt
            }
            $outcome = 'failedUnchanged'; $recovery = @()
            if ($null -ne $Context.record.workspace) {
                try { Remove-WindowsWorkspace $Context }
                catch { $outcome = 'partial'; $recovery = @($Context.record.receipt.recovery); $failure += '; cleanup: ' + $_.Exception.Message }
            } elseif ($null -ne $Context.record.receipt.plannedPaths) { $outcome = 'unknown' }
            $receipt = New-WindowsReceipt $Context 'terminal' $outcome
            $receipt.recovery = $recovery; $receipt.failure = $failure
            Save-WindowsReceipt $Context $receipt
        }
    }
    """#
}
