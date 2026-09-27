import Foundation

extension WindowsOperationScripts {
    static let treeImportHelpers = #"""
    function Prepare-WindowsImportedTree($Context) {
        $intent = $Context.record.intent
        $received = $Context.record.receipt
        if ($intent.action -ne 'copy' -or $null -eq $intent.treeProof -or $null -eq $intent.sourceManifest -or
            $received.phase -ne 'payloadReceived' -or -not $received.contentVerified -or
            $received.preparedPayload.observation.kind -ne 'file' -or $null -eq $Context.record.workspace) {
            throw 'Invalid accepted folder import.'
        }
        Add-Type -AssemblyName System.IO.Compression
        Assert-WindowsDestination $Context | Out-Null
        $source = Get-OperationPath $received.preparedPayload.location $Context.account
        $before = Get-WindowsContentProof $source
        Assert-WindowsObservation $before $received.preparedPayload.observation
        $receipt = New-WindowsReceipt $Context 'preparing' 'running'
        $receipt.preparedPayload = $received.preparedPayload
        Save-WindowsReceipt $Context $receipt | Out-Null
        $inputStream = [DetoursOperationFiles]::OpenObservedFile($source, $before.identity.volume, $before.identity.object, $before.version)
        try {
            $archive = [System.IO.Compression.ZipArchive]::new($inputStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                $plan = @(New-WindowsZipPlan $archive)
                $workspace = $Context.record.workspace
                $pin = [DetoursOperationFiles]::PinDirectory($Context.record.windowsWorkspacePath, $workspace.root.identity.volume, $workspace.root.identity.object)
                $directories = [System.Collections.Generic.List[System.IDisposable]]::new()
                try {
                    foreach ($member in $plan) {
                        Assert-WindowsOperationActive $Context
                        $name = if ($member.name.Length -eq 0) { 'tree' } else { 'tree/' + $member.name }
                        $target = Join-Path $Context.record.windowsWorkspacePath $name
                        if ($member.kind -eq 'directory') {
                            $created = [DetoursOperationFiles]::CreateDirectoryExclusive($target)
                            $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $name $created)
                            Save-WindowsWorkspace $Context
                            $directories.Add([DetoursOperationFiles]::PinDirectory($target, $created.identity.volume, $created.identity.object))
                        } else { Write-WindowsZipEntry $Context $member $target $name }
                    }
                    $payload = Join-Path $Context.record.windowsWorkspacePath 'tree'
                    $manifest = Get-WindowsTreeProof $payload
                    Assert-WindowsExtractedManifest $plan $manifest
                    if ($manifest.entries[0].observation.kind -ne 'directory' -or
                        $manifest.proof.sha256 -cne $intent.treeProof.sha256 -or $manifest.proof.byteCount -ne $intent.treeProof.byteCount) {
                        throw 'Imported folder content differs from the accepted manifest.'
                    }
                    Assert-WindowsObservation (Get-WindowsContentProof $source) $before
                    $Context.record | Add-Member -NotePropertyName payloadManifest -NotePropertyValue $manifest -Force
                    $Context.record | Add-Member -NotePropertyName sourceManifest -NotePropertyValue $intent.sourceManifest -Force
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
        } finally { $inputStream.Dispose() }
    }
    """#
}
