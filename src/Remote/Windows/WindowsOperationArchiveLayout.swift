import Foundation

extension WindowsOperationScripts {
    static let archiveLayoutHelpers = #"""
    function Get-WindowsArchiveLayout([string]$Path, [string]$Format, [string]$Password, [string]$Root, $Before) {
        if (-not [string]::IsNullOrEmpty($Password)) { throw 'Password-protected archives are not supported on Windows remote machines.' }
        if ($Before.kind -ne 'file') { throw 'Archive source is not a file.' }
        $input = [DetoursOperationFiles]::OpenObservedFile($Path, $Before.identity.volume, $Before.identity.object, $Before.version)
        try {
            $names = @()
            if ($Format -eq 'zip') {
                Add-Type -AssemblyName System.IO.Compression
                $archive = [System.IO.Compression.ZipArchive]::new($input, [System.IO.Compression.ZipArchiveMode]::Read, $true)
                try { $names = @($archive.Entries | ForEach-Object { $_.FullName }) } finally { $archive.Dispose() }
            } elseif ($Format -eq 'sevenZ') {
                $tool = Resolve-ArchiveTool @('7z.exe', '7z')
                $library = [DetoursSevenZipLibrary]::new((Join-Path ([System.IO.Path]::GetDirectoryName($tool)) '7z.dll'))
                try {
                    $archive = $library.OpenArchive($input, (Join-Path $Root ('layout-' + [guid]::NewGuid().ToString('D') + '.cancel')))
                    try { $names = @($archive.Entries | ForEach-Object { $_.FullName }) } finally { $archive.Dispose() }
                } finally { $library.Dispose() }
            } elseif ($Format -in @('tarGz', 'tarBz2', 'tarXz')) {
                $tool = Resolve-ArchiveTool @('tar.exe', 'tar')
                $output = [System.IO.MemoryStream]::new()
                try {
                    $process = [DetoursArchiveProcess]::new($tool, @('-tf', $Path), ([System.IO.Path]::GetDirectoryName($Path)), $output)
                    try {
                        $deadline = [DateTime]::UtcNow.AddSeconds(10)
                        while (-not $process.Wait(100)) {
                            if ([DateTime]::UtcNow -ge $deadline) { throw 'Archive layout inspection timed out.' }
                        }
                        $process.Complete()
                        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($output.ToArray())
                        $names = @($text -split '\r?\n' | Where-Object { $_.Length -gt 0 })
                    } finally { $process.Dispose() }
                } finally { $output.Dispose() }
            } else { throw 'Unsupported archive format.' }
            $entries = @($names | ForEach-Object {
                $name = $_.Replace('\', '/')
                while ($name.StartsWith('./')) { $name = $name.Substring(2) }
                if ($name.Length -gt 0) { [pscustomobject]@{ FullName = $name } }
            })
            New-WindowsZipPlan ([pscustomobject]@{ Entries = $entries }) | Out-Null
            $roots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $entries) { $roots.Add($entry.FullName.Split('/')[0]) | Out-Null }
            Assert-WindowsObservation (Get-WindowsContentProof $Path) $Before
            $single = if ($roots.Count -eq 1) { @($roots)[0] } else { $null }
            return @{ source = $Before; singleRoot = $single }
        } finally { $input.Dispose() }
    }
    """#
}
