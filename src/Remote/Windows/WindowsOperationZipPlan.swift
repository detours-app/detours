import Foundation

extension WindowsOperationScripts {
    static let zipPlanHelpers = #"""
    function New-WindowsZipPlan($Archive) {
        $members = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $roots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $Archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $directory = $name.EndsWith('/')
            if ($directory) { $name = $name.TrimEnd('/') }
            if ([string]::IsNullOrEmpty($name) -or $name.StartsWith('/')) { throw 'Invalid ZIP entry path.' }
            $parts = @($name.Split('/'))
            foreach ($part in $parts) {
                if ([string]::IsNullOrEmpty($part) -or $part -in @('.', '..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
                    $part.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'ZIP entry is not a safe Windows name.' }
            }
            $roots.Add($parts[0]) | Out-Null
            for ($index = 0; $index -lt $parts.Count; $index++) {
                $relative = [string]::Join('/', $parts[0..$index])
                $kind = if ($index -lt $parts.Count - 1 -or $directory) { 'directory' } else { 'file' }
                if ($members.ContainsKey($relative)) {
                    if ($kind -ne 'directory' -or $members[$relative].kind -ne 'directory') { throw 'ZIP entries have conflicting names.' }
                    if ($index -eq $parts.Count - 1) { $members[$relative].entry = $entry }
                } else {
                    $members.Add($relative, [pscustomobject]@{ name = $relative; kind = $kind
                        entry = $(if ($index -eq $parts.Count - 1) { $entry } else { $null }); sha256 = $null; byteCount = 0 })
                }
            }
        }
        if ($members.Count -eq 0) { throw 'Archive appears to be empty.' }
        $single = if ($roots.Count -eq 1) { @($roots)[0] } else { $null }
        $result = @()
        if ($null -eq $single) { $result += [pscustomobject]@{ name = ''; kind = 'directory'; entry = $null; sha256 = $null; byteCount = 0 } }
        foreach ($member in ($members.Values | Sort-Object { @($_.name.Split('/')).Count }, name)) {
            if ($null -ne $single) { $member.name = if ($member.name -ceq $single) { '' } else { $member.name.Substring($single.Length + 1) } }
            $result += $member
        }
        @($result)
    }
    function Assert-WindowsExtractedManifest($Plan, $Manifest) {
        if (@($Plan).Count -ne @($Manifest.entries).Count) { throw 'Extracted archive membership changed.' }
        foreach ($member in $Plan) {
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($member.name))
            $matches = @($Manifest.entries | Where-Object { $_.relativePath -ceq $encoded })
            if ($matches.Count -ne 1 -or $matches[0].observation.kind -cne $member.kind) { throw 'Extracted archive object changed.' }
            if ($member.kind -eq 'file' -and ($matches[0].observation.sha256 -cne $member.sha256 -or
                $matches[0].observation.byteCount -ne $member.byteCount)) { throw 'Extracted archive content changed.' }
        }
    }
    """#
}
