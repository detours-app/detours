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
        $plan = [DetoursOperationFiles]::PlanCopy($Source)
        $parent = [DetoursOperationFiles]::Observe([System.IO.Path]::GetDirectoryName($Destination))
        foreach ($entry in $plan.manifest.entries) {
            if ($entry.observation.identity.volume -ceq $parent.identity.volume -and $entry.observation.identity.object -ceq $parent.identity.object) {
                throw 'Cannot copy a folder into itself.'
            }
        }
        $Context.record | Add-Member -NotePropertyName sourceManifest -NotePropertyValue $manifest -Force
        $Context.record | Add-Member -NotePropertyName windowsCopyPlan -NotePropertyValue $plan -Force
        Save-WindowsWorkspace $Context
        New-WindowsWorkspace $Context $Destination | Out-Null
        $workspace = $Context.record.workspace
        $pin = [DetoursOperationFiles]::PinDirectory($Context.record.windowsWorkspacePath, $workspace.root.identity.volume, $workspace.root.identity.object)
        $directories = [System.Collections.Generic.List[System.IDisposable]]::new()
        try {
            foreach ($entry in $plan.inputs) {
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
                    $origin = $entry.sourcePath
                    Copy-WindowsTreeFile $Context $origin $target $name $entry.observation
                }
            }
            for ($index = @($plan.inputs).Count - 1; $index -ge 0; $index--) {
                $entry = $plan.inputs[$index]
                if ($entry.observation.kind -ne 'directory') { continue }
                $relative = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.relativePath))
                $origin = $entry.sourcePath
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
            $finalPlan = [DetoursOperationFiles]::PlanCopy($Source)
            Assert-WindowsCopyPlan $plan $finalPlan
            if ($prepared.proof.sha256 -cne $plan.manifest.proof.sha256 -or $prepared.proof.byteCount -ne $plan.manifest.proof.byteCount) {
                throw 'Prepared folder content does not match the source.'
            }
            $Context.record | Add-Member -NotePropertyName payloadManifest -NotePropertyValue $prepared -Force
            Save-WindowsWorkspace $Context
            Assert-WindowsOperationActive $Context
            $receipt = New-WindowsReceipt $Context 'readyToCommit' 'running'
            $observed = if ($prepared.entries[0].observation.kind -eq 'file') { Get-WindowsContentProof $payload } else { Get-WindowsManifestObservation $prepared }
            $receipt.preparedPayload = @{ location = (Get-WindowsOperationLocation $payload $Context.account); observation = $observed }
            $receipt.contentVerified = $true
            Save-WindowsReceipt $Context $receipt
        } finally {
            foreach ($directory in $directories) { $directory.Dispose() }
            $pin.Dispose()
        }
    }
    function Assert-WindowsCopyPlan($Before, $After) {
        Assert-WindowsTreeMovement $Before.manifest $After.manifest
        foreach ($field in @('inputs', 'links')) {
            $expected = @($Before.$field); $actual = @($After.$field)
            if ($expected.Count -ne $actual.Count) { throw 'Copy source plan changed.' }
            for ($index = 0; $index -lt $expected.Count; $index++) {
                if ($expected[$index].relativePath -cne $actual[$index].relativePath -or $expected[$index].sourcePath -cne $actual[$index].sourcePath) {
                    throw 'Copy source target changed.'
                }
                Assert-WindowsObservation $actual[$index].observation $expected[$index].observation
            }
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
