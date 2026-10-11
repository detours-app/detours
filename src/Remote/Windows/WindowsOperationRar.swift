import Foundation

extension WindowsOperationScripts {
    static let rarHelpers = #"""
    function Open-WindowsRarLibrary([string]$Source) {
        try {
            $tool = Resolve-ArchiveTool @('7z.exe', '7z')
            $toolDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($tool))
            $sourceDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Source))
            if ([string]::Equals($toolDirectory, $sourceDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Archive-directory tools are not trusted.'
            }
            return [DetoursSevenZipLibrary]::new((Join-Path $toolDirectory '7z.dll'))
        } catch {
            throw 'RAR requires a compatible free 7-Zip installation. Download it from https://www.7-zip.org/download.html'
        }
    }
    function Assert-WindowsRarSources($Intent, $Account, [switch]$MetadataOnly) {
        if ($Intent.archiveFormat -ne 'rar' -or $Intent.action -ne 'archiveExtract') { return }
        $count = @($Intent.sources).Count
        if ($count -lt 1 -or $count -gt 1024 -or $count -ne @($Intent.sourceObservations).Count) { throw 'Invalid accepted RAR parts.' }
        $identities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $parent = $null
        for ($index = 0; $index -lt $count; $index++) {
            $path = Get-OperationPath $Intent.sources[$index] $Account
            $directory = [System.IO.Path]::GetDirectoryName($path)
            if ($index -eq 0) { $parent = [DetoursOperationFiles]::Observe($directory) }
            $current = [DetoursOperationFiles]::Observe($directory)
            if ($parent.kind -ne 'directory' -or $current.kind -ne 'directory' -or
                $parent.identity.volume -cne $current.identity.volume -or $parent.identity.object -cne $current.identity.object) {
                throw 'RAR parts must be siblings in one directory.'
            }
            $expected = $Intent.sourceObservations[$index]
            if ($expected.kind -ne 'file' -or [string]::IsNullOrEmpty($expected.sha256) -or
                -not $names.Add([System.IO.Path]::GetFileName($path)) -or
                -not $identities.Add($expected.identity.volume + ':' + $expected.identity.object)) { throw 'Invalid accepted RAR part proof.' }
            if ($MetadataOnly) {
                $actual = [DetoursOperationFiles]::Observe($path)
                if ($actual.kind -ne 'file' -or $actual.identity.volume -cne $expected.identity.volume -or
                    $actual.identity.object -cne $expected.identity.object -or $actual.version -cne $expected.version) {
                    throw 'RAR part changed.'
                }
            } else {
                $actual = Get-WindowsContentProof $path
                Assert-WindowsObservation $actual $expected
            }
            if ($actual.byteCount -ne $expected.byteCount) { throw 'RAR part changed.' }
            if ($null -ne $Intent.destination) {
                $target = Get-WindowsOperationLookup (Get-OperationPath $Intent.destination $Account)
                if ($target.ContainsKey('found') -and $target.found._0.identity.volume -ceq $expected.identity.volume -and
                    $target.found._0.identity.object -ceq $expected.identity.object) { throw 'RAR output cannot replace an archive part.' }
            }
        }
    }
    function New-WindowsRarPlan($Archive) {
        $explicit = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $spellings = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [long]$total = 0
        foreach ($entry in $Archive.Entries) {
            $name = $entry.FullName.Replace('\', '/').TrimEnd('/')
            if (-not $explicit.Add($name.Normalize())) { throw 'Duplicate or equivalent RAR member names.' }
            $parts = @($name.Split('/'))
            for ($index = 0; $index -lt $parts.Count; $index++) {
                $prefix = [string]::Join('/', $parts[0..$index])
                $key = $prefix.Normalize()
                if ($spellings.ContainsKey($key) -and $spellings[$key] -cne $prefix) { throw 'Equivalent RAR path components.' }
                $spellings[$key] = $prefix
                if ($parts[$index] -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Reserved Windows RAR member name.' }
            }
            if ($entry.Length -lt 0 -or $entry.Length -gt [long]::MaxValue - $total) { throw 'RAR expanded size is too large.' }
            if ($entry.Kind -eq 'file') { $total += $entry.Length }
            if ($entry.Kind -in @('symbolicLink', 'hardLink')) {
                $target = [string]$entry.LinkTarget
                if ([string]::IsNullOrEmpty($target) -or $target.StartsWith('/') -or $target.Contains('\') -or $target.Contains(':') -or
                    $target.IndexOf([char]0) -ge 0 -or @($target.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0 -or
                    ($entry.Kind -eq 'symbolicLink' -and $parts.Count -lt 2)) { throw 'RAR link escapes its extracted tree.' }
            }
        }
        New-WindowsTarPlan $Archive
    }
    function Get-WindowsRarLayout([string]$Path, [string]$Password, [string]$Root, $Account, $Before) {
        $library = Open-WindowsRarLibrary $Path
        try {
            $cancel = Join-Path $Root ('layout-' + [guid]::NewGuid().ToString('D') + '.cancel')
            $volumes = [DetoursRarVolumeSet]::new([DetoursOperationFiles], $library, $Path, $Password, $cancel, $null)
            try {
                $archive = $volumes.OpenArchive()
                try {
                    New-WindowsRarPlan $archive | Out-Null
                    $roots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($entry in $archive.Entries) { $roots.Add($entry.FullName.Replace('\', '/').Split('/')[0]) | Out-Null }
                    $volumes.Validate()
                    Assert-WindowsObservation (Get-WindowsContentProof $Path) $Before
                    $locations = @($volumes.Parts | ForEach-Object {
                        Get-WindowsOperationLocation (Join-Path ([System.IO.Path]::GetDirectoryName($Path)) $_.Name) $Account
                    })
                    $observations = @($volumes.Parts | ForEach-Object { $_.Observation })
                    $single = if ($roots.Count -eq 1) { @($roots)[0] } else { $null }
                    return @{ source = $observations[0]; singleRoot = $single; rarSources = $locations
                        rarObservations = $observations; rarBaseName = $volumes.BaseName }
                } finally { $archive.Dispose() }
            } finally { $volumes.Dispose() }
        } finally { $library.Dispose() }
    }
    """#
}
