import Foundation

extension WindowsOperationScripts {
    static let tarExtractionHelpers = #"""
    function Prepare-WindowsTarExtraction($Context, $Parameters) {
        $intent = $Context.record.intent
        if ($intent.action -ne 'archiveExtract' -or $intent.archiveFormat -notin @('tarGz', 'tarBz2', 'tarXz') -or
            @($intent.sources).Count -ne 1 -or @($intent.sourceObservations).Count -ne 1) { throw 'Invalid accepted TAR extraction.' }
        if ($intent.archiveEncrypted -ne $false -or -not [string]::IsNullOrEmpty($Parameters.password)) {
            throw 'Password-protected archives are not supported on Windows remote machines.'
        }
        $tool = Resolve-ArchiveTool @('tar.exe', 'tar')
        $destination = Assert-WindowsDestination $Context
        $source = Get-OperationPath $intent.sources[0] $Context.account
        $before = Get-WindowsContentProof $source
        Assert-WindowsObservation $before $intent.sourceObservations[0]
        $Context.record | Add-Member -NotePropertyName windowsArchiveSource -NotePropertyValue $before -Force
        Save-WindowsWorkspace $Context
        $sourcePin = [DetoursOperationFiles]::OpenObservedFile($source, $before.identity.volume, $before.identity.object, $before.version)
        try {
            New-WindowsWorkspace $Context $destination | Out-Null
            $intermediate = Join-Path $Context.record.windowsWorkspacePath 'archive.tar'
            $output = [DetoursOperationFiles]::CreateNewFile($intermediate)
            try {
                $created = [DetoursOperationFiles]::ObserveStream($output)
                $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject 'archive.tar' $created)
                Save-WindowsWorkspace $Context
                Write-WindowsArchiveProcess $Context $tool @('-cf', '-', '--format', 'pax', ('@' + $source)) ([System.IO.Path]::GetDirectoryName($source)) $output
                $output.Flush($true)
            } finally { $output.Dispose() }
            $observed = Get-WindowsContentProof $intermediate
            if ($observed.identity.volume -cne $created.identity.volume -or $observed.identity.object -cne $created.identity.object) {
                throw 'Decoded archive identity changed.'
            }
            $inputStream = [DetoursOperationFiles]::OpenObservedFile($intermediate, $observed.identity.volume, $observed.identity.object, $observed.version)
            try {
                $archive = [DetoursTarArchive]::new($inputStream)
                $plan = @(New-WindowsTarPlan $archive)
                Write-WindowsTarPayload $Context $plan
                Assert-WindowsObservation (Get-WindowsContentProof $source) $before
                Assert-WindowsObservation (Get-WindowsContentProof $intermediate) $observed
                $payload = Join-Path $Context.record.windowsWorkspacePath 'payload'
                $manifest = Get-WindowsTreeProof $payload
                Assert-WindowsExtractedManifest $plan $manifest
                $Context.record | Add-Member -NotePropertyName payloadManifest -NotePropertyValue $manifest -Force
                Save-WindowsWorkspace $Context
                Assert-WindowsOperationActive $Context
                $actual = if ($manifest.entries[0].observation.kind -eq 'file') { $manifest.entries[0].observation } else { Get-WindowsManifestObservation $manifest }
                $receipt = New-WindowsReceipt $Context 'readyToCommit' 'running'
                $receipt.preparedPayload = @{ location = (Get-WindowsOperationLocation $payload $Context.account); observation = $actual }
                $receipt.contentVerified = $true
                Save-WindowsReceipt $Context $receipt
            } finally { $inputStream.Dispose() }
        } finally { $sourcePin.Dispose() }
    }
    function Write-WindowsTarPayload($Context, $Plan) {
        $workspace = $Context.record.workspace
        $pin = [DetoursOperationFiles]::PinDirectory($Context.record.windowsWorkspacePath, $workspace.root.identity.volume, $workspace.root.identity.object)
        $directories = [System.Collections.Generic.List[System.IDisposable]]::new()
        try {
            foreach ($member in $Plan) {
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
                } else { Write-WindowsZipEntry $Context $member $target $name }
            }
            Write-WindowsTarLinks $Context $Plan
            foreach ($member in $Plan) {
                if ($member.kind -ne 'directory' -or $null -eq $member.entry) { continue }
                $name = if ($member.name.Length -eq 0) { 'payload' } else { 'payload/' + $member.name }
                $target = Join-Path $Context.record.windowsWorkspacePath $name
                [DetoursOperationFiles]::SetDirectoryTime($target, $member.created.identity.volume, $member.created.identity.object,
                    $member.entry.LastWriteTime.UtcDateTime.ToFileTimeUtc())
            }
        } finally {
            foreach ($directory in $directories) { $directory.Dispose() }
            $pin.Dispose()
        }
    }
    """#
}
