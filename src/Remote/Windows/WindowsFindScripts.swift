import Foundation

enum WindowsFindScripts {
    static let find = PowerShellScript.prelude(
        operationBody: #"""
        param($Arguments)
        $query = [string]$Arguments.query
        if ([string]::IsNullOrWhiteSpace($query)) { return @() }
        $cap = [Math]::Min([Math]::Max([int]$Arguments.cap, 1), 1000)
        $deadline = [DateTime]::UtcNow.AddSeconds(20)

        function Normalize-Path([string]$Path) {
            [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        }

        function Test-IsUnderOrSame([string]$Path, [string]$Parent) {
            $normalizedPath = Normalize-Path $Path
            $normalizedParent = Normalize-Path $Parent
            $comparison = [System.StringComparison]::OrdinalIgnoreCase
            $normalizedPath.Equals($normalizedParent, $comparison) -or
                $normalizedPath.StartsWith($normalizedParent + [System.IO.Path]::DirectorySeparatorChar, $comparison)
        }

        $active = Get-Item -LiteralPath $Arguments.root -Force
        $activePath = if ($active.PSIsContainer) { $active.FullName } else { $active.DirectoryName }
        $driveRoot = [System.IO.Path]::GetPathRoot($activePath)
        $root = Get-Item -LiteralPath $activePath -Force
        $noiseRoots = @(
            (Join-Path -Path $driveRoot -ChildPath 'Windows'),
            (Join-Path -Path $driveRoot -ChildPath 'Program Files'),
            (Join-Path -Path $driveRoot -ChildPath 'Program Files (x86)'),
            (Join-Path -Path $driveRoot -ChildPath 'ProgramData')
        )
        $userProfile = [Environment]::GetFolderPath('UserProfile')
        if (-not [string]::IsNullOrEmpty($userProfile) -and
            [System.IO.Path]::GetPathRoot($userProfile).Equals($driveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $noiseRoots += (Join-Path -Path $userProfile -ChildPath 'AppData')
        }
        $noiseRoots = @($noiseRoots | Where-Object { Test-Path -LiteralPath $_ })

        function Test-ShouldPrune([string]$Directory) {
            foreach ($noiseRoot in $noiseRoots) {
                if (Test-IsUnderOrSame -Path $activePath -Parent $noiseRoot) { continue }
                if (Test-IsUnderOrSame -Path $Directory -Parent $noiseRoot) { return $true }
            }
            return $false
        }

        $results = [System.Collections.Generic.List[object]]::new()
        $stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
        $stack.Push([System.IO.DirectoryInfo]$root.FullName)
        while ($stack.Count -gt 0 -and $results.Count -lt $cap -and [DateTime]::UtcNow -lt $deadline) {
            $directory = $stack.Pop()
            $children = @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue)
            foreach ($child in $children) {
                if ($results.Count -ge $cap -or [DateTime]::UtcNow -ge $deadline) { break }
                if ($child.Name.IndexOf($query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $results.Add([pscustomobject]@{
                        FullName = $child.FullName
                        PSIsContainer = [bool]$child.PSIsContainer
                    })
                }
                if ($child.PSIsContainer -and -not (Test-ShouldPrune -Directory $child.FullName)) {
                    $stack.Push([System.IO.DirectoryInfo]$child.FullName)
                }
            }
        }
        $results
        """#
    )

    static let gitStatus = PowerShellScript.prelude(
        operationBody: #"""
        param($Arguments)
        $git = Get-Command -Name 'git.exe', 'git' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $git) { return @() }

        $rootOutput = & $git.Source -C $Arguments.path rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rootOutput)) { return @() }
        $gitRoot = ([string]$rootOutput).Trim()
        $statusOutput = & $git.Source -C $Arguments.path status --porcelain=v1 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }

        function Convert-GitQuotedName([string]$Name) {
            if ($Name.Length -lt 2 -or -not ($Name.StartsWith('"') -and $Name.EndsWith('"'))) {
                return $Name
            }
            $inner = $Name.Substring(1, $Name.Length - 2)
            $bytes = New-Object System.Collections.Generic.List[byte]
            $i = 0
            while ($i -lt $inner.Length) {
                if ($inner[$i] -eq '\' -and ($i + 1) -lt $inner.Length) {
                    $next = $inner[$i + 1]
                    if ('01234567'.Contains([string]$next) -and ($i + 4) -le $inner.Length) {
                        $bytes.Add([Convert]::ToByte($inner.Substring($i + 1, 3), 8))
                        $i += 4
                    } elseif ($next -eq 'n') { $bytes.Add([byte]10); $i += 2 }
                    elseif ($next -eq 't') { $bytes.Add([byte]9); $i += 2 }
                    elseif ($next -eq 'r') { $bytes.Add([byte]13); $i += 2 }
                    else {
                        foreach ($b in [System.Text.Encoding]::UTF8.GetBytes([string]$next)) { $bytes.Add($b) }
                        $i += 2
                    }
                } else {
                    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes([string]$inner[$i])) { $bytes.Add($b) }
                    $i += 1
                }
            }
            [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
        }

        function Convert-GitStatus([char]$Index, [char]$WorkTree) {
            if ($Index -eq '?' -and $WorkTree -eq '?') { return 'untracked' }
            if ($Index -eq 'U' -or $WorkTree -eq 'U' -or
                ($Index -eq 'A' -and $WorkTree -eq 'A') -or
                ($Index -eq 'D' -and $WorkTree -eq 'D')) { return 'conflict' }
            if ($Index -ne ' ' -and $Index -ne '?') {
                if ($WorkTree -eq ' ') { return 'staged' }
                return 'modified'
            }
            if ($WorkTree -eq 'M' -or $WorkTree -eq 'D') { return 'modified' }
            return 'clean'
        }

        foreach ($line in @($statusOutput)) {
            if ($line.Length -lt 3) { continue }
            $index = [char]$line[0]
            $workTree = [char]$line[1]
            $fileName = $line.Substring(3)
            $arrowIndex = $fileName.IndexOf(' -> ')
            if ($arrowIndex -ge 0) {
                $fileName = $fileName.Substring($arrowIndex + 4)
            }
            $fileName = Convert-GitQuotedName -Name $fileName
            $status = Convert-GitStatus -Index $index -WorkTree $workTree
            if ($status -eq 'clean') { continue }
            [pscustomobject]@{
                FullName = (Join-Path -Path $gitRoot -ChildPath $fileName)
                Status = $status
            }
        }
        """#
    )
}
