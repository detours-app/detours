import Foundation

extension WindowsOperationScripts {
    static let tarLinkHelpers = #"""
    function New-WindowsTarPlan($Archive) {
        $plan = @(New-WindowsZipPlan $Archive)
        foreach ($member in $plan) {
            if ($null -eq $member.entry) { continue }
            if ($member.entry.Kind -eq 'symbolicLink') { $member.kind = 'symbolicLink' }
            if ($member.entry.Kind -ne 'hardLink') { continue }
            $target = $member; $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            while ($target.entry.Kind -eq 'hardLink') {
                if (-not $visited.Add($target.entry.FullName)) { throw 'Archive hard links contain a cycle.' }
                $name = $target.entry.LinkTarget.Replace('\', '/')
                while ($name.StartsWith('./')) { $name = $name.Substring(2) }
                $matches = @($plan | Where-Object { $null -ne $_.entry -and $_.entry.FullName.Replace('\', '/') -ceq $name })
                if ($matches.Count -ne 1) { throw 'Archive hard link target is not a recorded member.' }
                $target = $matches[0]
            }
            if ($target.entry.Kind -ne 'file') { throw 'Archive hard links require a regular-file target.' }
            $member | Add-Member -NotePropertyName hardLink -NotePropertyValue $target
        }
        @($plan)
    }
    function Write-WindowsTarLinks($Context, $Plan) {
        foreach ($member in $Plan) {
            if ($null -eq $member.hardLink) { continue }
            Assert-WindowsOperationActive $Context
            $sourceName = if ($member.hardLink.name.Length -eq 0) { 'payload' } else { 'payload/' + $member.hardLink.name }
            $name = if ($member.name.Length -eq 0) { 'payload' } else { 'payload/' + $member.name }
            $source = Join-Path $Context.record.windowsWorkspacePath $sourceName
            $target = Join-Path $Context.record.windowsWorkspacePath $name
            $observed = Get-WindowsContentProof $source
            if ($observed.sha256 -cne $member.hardLink.sha256 -or $observed.byteCount -ne $member.hardLink.byteCount) {
                throw 'Archive hard link source changed.'
            }
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sourceName))
            $owned = @($Context.record.workspace.objects | Where-Object { $_.name -ceq $encoded })
            if ($owned.Count -ne 1 -or $owned[0].identity.volume -cne $observed.identity.volume -or
                $owned[0].identity.object -cne $observed.identity.object) { throw 'Archive hard link source is not owned.' }
            $created = [DetoursOperationFiles]::CreateArchiveHardLink($source, $target, $observed.identity.volume, $observed.identity.object, $observed.version)
            $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $name $created)
            Save-WindowsWorkspace $Context
            $member.sha256 = $member.hardLink.sha256; $member.byteCount = $member.hardLink.byteCount
        }
        foreach ($member in $Plan) {
            if ($member.kind -ne 'symbolicLink') { continue }
            Assert-WindowsOperationActive $Context
            $name = if ($member.name.Length -eq 0) { 'payload' } else { 'payload/' + $member.name }
            $target = Join-Path $Context.record.windowsWorkspacePath $name
            $linkTarget = $member.entry.LinkTarget.Replace('/', '\')
            if ([string]::IsNullOrEmpty($linkTarget) -or $linkTarget.IndexOf([char]0) -ge 0) { throw 'Invalid archive symbolic link target.' }
            $logicalRoot = $Context.record.windowsWorkspacePath
            $logicalParent = [System.IO.Path]::GetDirectoryName((Join-Path $logicalRoot $member.entry.FullName))
            $logicalTarget = [System.IO.Path]::GetFullPath((Join-Path $logicalParent $linkTarget))
            $directory = $false
            foreach ($candidate in $Plan) {
                if ($candidate.kind -ne 'directory' -or $null -eq $candidate.entry) { continue }
                $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $logicalRoot $candidate.entry.FullName)).TrimEnd('\')
                if ([string]::Equals($candidatePath, $logicalTarget.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { $directory = $true }
            }
            $created = [DetoursOperationFiles]::CreateArchiveSymbolicLink($target, $linkTarget, $directory)
            $Context.record.workspace.objects = @($Context.record.workspace.objects) + @(New-WindowsOwnedObject $name $created)
            Save-WindowsWorkspace $Context
            [DetoursOperationFiles]::SetArchiveTime($target, $created.identity.volume, $created.identity.object, 'symbolicLink',
                $member.entry.LastWriteTime.UtcDateTime.ToFileTimeUtc())
            $member | Add-Member -NotePropertyName linkObservation -NotePropertyValue ([DetoursOperationFiles]::Observe($target))
        }
    }
    """#
}
