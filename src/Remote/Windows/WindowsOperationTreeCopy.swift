import Foundation

extension WindowsOperationScripts {
    static let treeCopyHelpers = #"""
    function Remove-WindowsOwnedDescendants($Context, [string]$Path, [string]$Relative, $Identity) {
        $pin = [DetoursOperationFiles]::PinDirectory($Path, $Identity.volume, $Identity.object)
        try {
            $children = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
            foreach ($entry in $Context.record.workspace.objects) {
                $name = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.name))
                if ($name.Contains('\') -or $name.StartsWith('/') -or @($name.Split('/')) -contains '..') { throw 'Invalid owned tree path.' }
                $separator = $name.LastIndexOf('/')
                $parent = if ($separator -lt 0) { '' } else { $name.Substring(0, $separator) }
                if ($parent -ceq $Relative) { $children.Add($name.Substring($separator + 1), $entry) }
            }
            $entries = [System.IO.Directory]::GetFileSystemEntries($Path)
            foreach ($child in $entries) {
                if (-not $children.ContainsKey([System.IO.Path]::GetFileName($child))) { throw 'Operation workspace contains an unrecorded object.' }
            }
            foreach ($child in $entries) {
                $entry = $children[[System.IO.Path]::GetFileName($child)]
                if ($entry.kind -eq 'directory') {
                    $relativeChild = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.name))
                    Remove-WindowsOwnedDescendants $Context $child $relativeChild $entry.identity
                }
                [DetoursOperationFiles]::RemoveOwned($child, $entry.identity.volume, $entry.identity.object)
            }
        } finally { $pin.Dispose() }
    }
    function Prepare-WindowsTreePayload($Context, [string]$Source, [string]$Destination) {
        $manifest = Get-WindowsTreeProof $Source
        $before = Get-WindowsManifestObservation $manifest
        Assert-WindowsObservation $before $Context.record.intent.sourceObservations[0]
        if (@($manifest.entries | Where-Object { $_.observation.kind -eq 'symbolicLink' }).Count -gt 0) {
            throw 'Accepted Windows tree copy does not yet support link transformation.'
        }
        $parent = [DetoursOperationFiles]::Observe([System.IO.Path]::GetDirectoryName($Destination))
        foreach ($entry in $manifest.entries) {
            if ($entry.observation.identity.volume -ceq $parent.identity.volume -and $entry.observation.identity.object -ceq $parent.identity.object) {
                throw 'Cannot copy a folder into itself.'
            }
        }
        $Context.record | Add-Member -NotePropertyName sourceManifest -NotePropertyValue $manifest -Force
        Save-WindowsWorkspace $Context
        New-WindowsWorkspace $Context $Destination | Out-Null
        $workspace = $Context.record.workspace
        $pin = [DetoursOperationFiles]::PinDirectory($Context.record.windowsWorkspacePath, $workspace.root.identity.volume, $workspace.root.identity.object)
        $directories = [System.Collections.Generic.List[System.IDisposable]]::new()
        try {
            foreach ($entry in $manifest.entries) {
                Assert-WindowsOperationActive $Context
                $relative = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.relativePath))
                $name = if ($relative.Length -eq 0) { 'payload' } else { 'payload/' + $relative }
                $target = Join-Path $Context.record.windowsWorkspacePath $name
                if ($entry.observation.kind -eq 'directory') {
                    $created = [DetoursOperationFiles]::CreateDirectoryExclusive($target)
                    $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $name $created)
                    Save-WindowsWorkspace $Context
                    $directories.Add([DetoursOperationFiles]::PinDirectory($target, $created.identity.volume, $created.identity.object))
                } else {
                    $origin = if ($relative.Length -eq 0) { $Source } else { Join-Path $Source $relative }
                    Copy-WindowsTreeFile $Context $origin $target $name $entry.observation
                }
            }
            for ($index = @($manifest.entries).Count - 1; $index -ge 0; $index--) {
                $entry = $manifest.entries[$index]
                if ($entry.observation.kind -ne 'directory') { continue }
                $relative = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.relativePath))
                $origin = if ($relative.Length -eq 0) { $Source } else { Join-Path $Source $relative }
                $target = Join-Path $Context.record.windowsWorkspacePath 'payload'
                if ($relative.Length -gt 0) { $target = Join-Path $target $relative }
                $name = if ($relative.Length -eq 0) { 'payload' } else { 'payload/' + $relative }
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($name))
                $owned = @($Context.record.workspace.objects | Where-Object { $_.name -ceq $encoded })
                if ($owned.Count -ne 1) { throw 'Directory metadata ownership is missing.' }
                [DetoursOperationFiles]::CopyDirectoryMetadata($origin, $target, $owned[0].identity.volume, $owned[0].identity.object)
            }
            $payload = Join-Path $Context.record.windowsWorkspacePath 'payload'
            $prepared = Get-WindowsTreeProof $payload
            $after = Get-WindowsTreeProof $Source
            Assert-WindowsTreeMovement $manifest $after
            for ($index = 0; $index -lt @($manifest.entries).Count; $index++) {
                Assert-WindowsObservation $after.entries[$index].observation $manifest.entries[$index].observation
            }
            if ($prepared.proof.sha256 -cne $manifest.proof.sha256 -or $prepared.proof.byteCount -ne $manifest.proof.byteCount) {
                throw 'Prepared folder content does not match the source.'
            }
            $Context.record | Add-Member -NotePropertyName payloadManifest -NotePropertyValue $prepared -Force
            Save-WindowsWorkspace $Context
            Assert-WindowsOperationActive $Context
            $receipt = New-WindowsReceipt $Context 'readyToCommit' 'running'
            $receipt.preparedPayload = @{ location = (Get-WindowsOperationLocation $payload $Context.account)
                observation = (Get-WindowsManifestObservation $prepared) }
            $receipt.contentVerified = $true
            Save-WindowsReceipt $Context $receipt
        } finally {
            foreach ($directory in $directories) { $directory.Dispose() }
            $pin.Dispose()
        }
    }
    function Copy-WindowsTreeFile($Context, [string]$Source, [string]$Target, [string]$Name, $Expected) {
        $sourceStream = [DetoursOperationFiles]::OpenObservedFile($Source, $Expected.identity.volume, $Expected.identity.object, $Expected.version)
        try {
            $output = [DetoursOperationFiles]::CreateNewFile($Target)
            try {
                $created = [DetoursOperationFiles]::ObserveStream($output)
                $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $Name $created)
                Save-WindowsWorkspace $Context
                $buffer = [byte[]]::new(65536)
                while (($count = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    Assert-WindowsOperationActive $Context
                    $output.Write($buffer, 0, $count)
                }
                $output.Flush($true)
            } finally { $output.Dispose() }
            [System.IO.File]::SetLastWriteTimeUtc($Target, [System.IO.File]::GetLastWriteTimeUtc($Source))
            [System.IO.File]::SetAttributes($Target, [System.IO.File]::GetAttributes($Source))
        } finally { $sourceStream.Dispose() }
    }
    """#
}
