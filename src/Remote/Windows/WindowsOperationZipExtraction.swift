import Foundation

extension WindowsOperationScripts {
    static let zipExtractionHelpers = #"""
    function Prepare-WindowsZipExtraction($Context, $Parameters) {
        $intent = $Context.record.intent
        if ($intent.archiveFormat -ne 'zip' -or @($intent.sources).Count -ne 1 -or @($intent.sourceObservations).Count -ne 1) {
            throw 'Invalid accepted ZIP extraction.'
        }
        if ($intent.archiveEncrypted -ne $false -or -not [string]::IsNullOrEmpty($Parameters.password)) {
            throw 'Password-protected archives are not supported on Windows remote machines.'
        }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $destination = Assert-WindowsDestination $Context
        $source = Get-OperationPath $intent.sources[0] $Context.account
        $before = Get-WindowsContentProof $source
        Assert-WindowsObservation $before $intent.sourceObservations[0]
        $Context.record | Add-Member -NotePropertyName windowsArchiveSource -NotePropertyValue $before -Force
        Save-WindowsWorkspace $Context
        $inputStream = [DetoursOperationFiles]::OpenObservedFile($source, $before.identity.volume, $before.identity.object, $before.version)
        try {
            $archive = [System.IO.Compression.ZipArchive]::new($inputStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                $plan = @(New-WindowsZipPlan $archive)
                New-WindowsWorkspace $Context $destination | Out-Null
                $workspace = $Context.record.workspace
                $pin = [DetoursOperationFiles]::PinDirectory($Context.record.windowsWorkspacePath, $workspace.root.identity.volume, $workspace.root.identity.object)
                $directories = [System.Collections.Generic.List[System.IDisposable]]::new()
                try {
                    foreach ($member in $plan) {
                        Assert-WindowsOperationActive $Context
                        $name = if ($member.name.Length -eq 0) { 'payload' } else { 'payload/' + $member.name }
                        $target = Join-Path $Context.record.windowsWorkspacePath $name
                        if ($member.kind -eq 'directory') {
                            $created = [DetoursOperationFiles]::CreateDirectoryExclusive($target)
                            $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $name $created)
                            Save-WindowsWorkspace $Context
                            $directories.Add([DetoursOperationFiles]::PinDirectory($target, $created.identity.volume, $created.identity.object))
                        } else { Write-WindowsZipEntry $Context $member $target $name }
                    }
                    $payload = Join-Path $Context.record.windowsWorkspacePath 'payload'
                    $manifest = Get-WindowsTreeProof $payload
                    Assert-WindowsExtractedManifest $plan $manifest
                    Assert-WindowsObservation (Get-WindowsContentProof $source) $before
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
        } finally { $inputStream.Dispose() }
    }
    function Write-WindowsZipEntry($Context, $Member, [string]$Target, [string]$Name) {
        $output = [DetoursOperationFiles]::CreateNewFile($Target)
        try {
            $created = [DetoursOperationFiles]::ObserveStream($output)
            $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $Name $created)
            Save-WindowsWorkspace $Context
            $entryStream = $Member.entry.Open()
            $hash = [System.Security.Cryptography.SHA256]::Create()
            try {
                $buffer = [byte[]]::new(65536); $received = [long]0
                while (($count = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    Assert-WindowsOperationActive $Context
                    $hash.TransformBlock($buffer, 0, $count, $buffer, 0) | Out-Null
                    $output.Write($buffer, 0, $count); $received += $count
                }
                if ($received -ne $Member.entry.Length) { throw 'Extracted ZIP entry length changed.' }
                $hash.TransformFinalBlock([byte[]]::new(0), 0, 0) | Out-Null
                $Member.sha256 = [BitConverter]::ToString($hash.Hash).Replace('-', '').ToLowerInvariant()
                $Member.byteCount = $received
                $output.Flush($true)
            } finally { $hash.Dispose(); $entryStream.Dispose() }
        } finally { $output.Dispose() }
        [System.IO.File]::SetLastWriteTimeUtc($Target, $Member.entry.LastWriteTime.UtcDateTime)
    }
    """#
}
