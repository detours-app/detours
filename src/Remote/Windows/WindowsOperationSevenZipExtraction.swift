import Foundation

extension WindowsOperationScripts {
    static let sevenZipExtractionHelpers = #"""
    function Prepare-WindowsSevenZipExtraction($Context, $Parameters) {
        $intent = $Context.record.intent
        $rar = $intent.archiveFormat -eq 'rar'
        if ($intent.archiveFormat -notin @('sevenZ', 'rar') -or @($intent.sources).Count -lt 1 -or
            @($intent.sources).Count -ne @($intent.sourceObservations).Count -or (-not $rar -and @($intent.sources).Count -ne 1)) {
            throw 'Invalid accepted 7z extraction.'
        }
        if (-not $rar -and ($intent.archiveEncrypted -ne $false -or -not [string]::IsNullOrEmpty($Parameters.password))) {
            throw 'Password-protected archives are not supported on Windows remote machines.'
        }
        $destination = Assert-WindowsDestination $Context
        $source = Get-OperationPath $intent.sources[0] $Context.account
        if ($rar) { Assert-WindowsRarSources $intent $Context.account }
        $before = Get-WindowsContentProof $source
        Assert-WindowsObservation $before $intent.sourceObservations[0]
        $Context.record | Add-Member -NotePropertyName windowsArchiveSource -NotePropertyValue $before -Force
        Save-WindowsWorkspace $Context
        $inputStream = $null; $volumes = $null
        try {
            if ($rar) { $library = Open-WindowsRarLibrary $source }
            else {
                $tool = Resolve-ArchiveTool @('7z.exe', '7z')
                $library = [DetoursSevenZipLibrary]::new((Join-Path ([System.IO.Path]::GetDirectoryName($tool)) '7z.dll'))
            }
            try {
                $cancel = Join-Path $Context.root ((Get-OperationKey $Context.identity.id) + '.cancel')
                if ($rar) {
                    $names = [string[]]@($intent.sources | ForEach-Object { [System.IO.Path]::GetFileName((Get-OperationPath $_ $Context.account)) })
                    $volumes = [DetoursRarVolumeSet]::new([DetoursOperationFiles], $library, $source, $Parameters.password, $cancel, $names)
                    $archive = $volumes.OpenArchive()
                } else {
                    $inputStream = [DetoursOperationFiles]::OpenObservedFile($source, $before.identity.volume, $before.identity.object, $before.version)
                    $archive = $library.OpenArchive($inputStream, $cancel)
                }
                try {
                    $plan = if ($rar) { @(New-WindowsRarPlan $archive) } else { @(New-WindowsTarPlan $archive) }
                    if ($rar) {
                        Assert-WindowsRarSources $intent $Context.account
                        [long]$expanded = 0
                        foreach ($entry in $archive.Entries) { if ($entry.Kind -eq 'file') { $expanded += $entry.Length } }
                        if ([ulong]$expanded -gt [DetoursSevenZipLibrary]::AvailableBytes([System.IO.Path]::GetDirectoryName($destination))) {
                            throw 'Not enough free space to extract this RAR archive.'
                        }
                    }
                    New-WindowsWorkspace $Context $destination | Out-Null
                    $workspace = $Context.record.workspace
                    $pin = [DetoursOperationFiles]::PinDirectory($Context.record.windowsWorkspacePath, $workspace.root.identity.volume, $workspace.root.identity.object)
                    $directories = [System.Collections.Generic.List[System.IDisposable]]::new()
                    try {
                        foreach ($member in $plan) {
                            Assert-WindowsOperationActive $Context
                            if ($member.kind -eq 'symbolicLink' -or $null -ne $member.hardLink) { continue }
                            $name = if ($member.name.Length -eq 0) { 'payload' } else { 'payload/' + $member.name }
                            $target = Join-Path $Context.record.windowsWorkspacePath $name
                            if ($member.kind -eq 'directory') {
                                $created = [DetoursOperationFiles]::CreateDirectoryExclusive($target)
                                $member | Add-Member -NotePropertyName created -NotePropertyValue $created
                                $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $name $created)
                                Save-WindowsWorkspace $Context
                                $directories.Add([DetoursOperationFiles]::PinDirectory($target, $created.identity.volume, $created.identity.object))
                            } else { Write-WindowsSevenZipEntry $Context $archive $member $target $name }
                        }
                        Write-WindowsTarLinks $Context $plan
                        foreach ($member in $plan) {
                            if ($member.kind -ne 'directory' -or $null -eq $member.entry) { continue }
                            $name = if ($member.name.Length -eq 0) { 'payload' } else { 'payload/' + $member.name }
                            $target = Join-Path $Context.record.windowsWorkspacePath $name
                            [DetoursOperationFiles]::SetDirectoryTime($target, $member.created.identity.volume, $member.created.identity.object,
                                $member.entry.LastWriteTime.UtcDateTime.ToFileTimeUtc())
                        }
                        $payload = Join-Path $Context.record.windowsWorkspacePath 'payload'
                        $manifest = Get-WindowsTreeProof $payload
                        Assert-WindowsExtractedManifest $plan $manifest
                        Assert-WindowsObservation (Get-WindowsContentProof $source) $before
                        if ($rar) { $volumes.Validate(); Assert-WindowsRarSources $intent $Context.account }
                        $Context.record | Add-Member -NotePropertyName payloadManifest -NotePropertyValue $manifest -Force
                        $Context.record | Add-Member -NotePropertyName windowsArchiveSource -NotePropertyValue $before -Force
                        Save-WindowsWorkspace $Context
                        Assert-WindowsOperationActive $Context
                        $observed = if ($manifest.entries[0].observation.kind -eq 'file') { $manifest.entries[0].observation } else { Get-WindowsManifestObservation $manifest }
                        $receipt = New-WindowsReceipt $Context 'readyToCommit' 'running'
                        $receipt.preparedPayload = @{ location = (Get-WindowsOperationLocation $payload $Context.account); observation = $observed }
                        $receipt.contentVerified = $true
                        Save-WindowsReceipt $Context $receipt
                    } finally {
                        foreach ($directory in $directories) { $directory.Dispose() }
                        $pin.Dispose()
                    }
                } finally { $archive.Dispose() }
            } finally {
                if ($null -ne $volumes) { $volumes.Dispose() }
                $library.Dispose()
            }
        } finally { if ($null -ne $inputStream) { $inputStream.Dispose() } }
    }
    function Write-WindowsSevenZipEntry($Context, $Archive, $Member, [string]$Target, [string]$Name) {
        $output = [DetoursOperationFiles]::CreateNewFile($Target)
        try {
            $created = [DetoursOperationFiles]::ObserveStream($output)
            $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $Name $created)
            Save-WindowsWorkspace $Context
            $Member.sha256 = $Archive.Extract($Member.entry, $output)
            $Member.byteCount = $Member.entry.Length
            $output.Flush($true)
        } finally { $output.Dispose() }
        [DetoursOperationFiles]::SetArchiveTime($Target, $created.identity.volume, $created.identity.object, 'file',
            $Member.entry.LastWriteTime.UtcDateTime.ToFileTimeUtc())
    }
    """#
}
