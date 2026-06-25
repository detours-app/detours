import Foundation

enum WindowsArchiveScripts {
    static let toolAvailability = PowerShellScript.prelude(
        operationBody: #"""
        param($Arguments)
        function Test-ArchiveTool($Names) {
            foreach ($name in $Names) {
                $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($null -ne $command) { return $true }
            }
            return $false
        }

        [pscustomobject]@{
            SevenZip = Test-ArchiveTool @('7z.exe', '7z')
            Tar = Test-ArchiveTool @('tar.exe', 'tar')
        }
        """#
    )

    static let zipCreate = PowerShellScript.prelude(
        operationBody: #"""
        param($Arguments)
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        \#(commonHelpers)
        \#(zipHelpers)

        $items = @($Arguments.items)
        $parent = Get-ArchiveParent -Items $items
        $archivePath = New-UniqueArchivePath -Directory $parent -BaseName $Arguments.archiveName -Extension 'zip'
        $fileStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $archive = [System.IO.Compression.ZipArchive]::new($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($path in $items) {
                $item = Get-Item -LiteralPath $path -Force
                Add-ZipItem -Archive $archive -Item $item -Root $parent
            }
        } finally {
            $archive.Dispose()
            $fileStream.Dispose()
        }
        $archivePath
        """#
    )

    static let externalCreate = PowerShellScript.prelude(
        operationBody: #"""
        param($Arguments)
        \#(commonHelpers)
        \#(externalToolHelpers)

        $items = @($Arguments.items)
        $parent = Get-ArchiveParent -Items $items
        $format = [string]$Arguments.format
        $extension = Get-ArchiveExtension -Format $format
        $archivePath = New-UniqueArchivePath -Directory $parent -BaseName $Arguments.archiveName -Extension $extension

        switch ($format) {
            'zip' {
                $tool = Resolve-ArchiveTool @('7z.exe', '7z')
                $arguments = @('a', '-tzip', $archivePath)
                $arguments += $items
                if (-not [string]::IsNullOrEmpty($Arguments.password)) {
                    $arguments += "-p$($Arguments.password)"
                    $arguments += '-mem=AES256'
                }
                Invoke-ArchiveTool -FilePath $tool -Arguments $arguments -WorkingDirectory $null
            }
            'sevenZ' {
                $tool = Resolve-ArchiveTool @('7z.exe', '7z')
                $arguments = @('a', '-t7z', $archivePath)
                $arguments += $items
                if (-not [string]::IsNullOrEmpty($Arguments.password)) {
                    $arguments += "-p$($Arguments.password)"
                    $arguments += '-mhe=on'
                }
                Invoke-ArchiveTool -FilePath $tool -Arguments $arguments -WorkingDirectory $null
            }
            default {
                if (-not [string]::IsNullOrEmpty($Arguments.password)) {
                    throw "Password-protected TAR archives are not supported."
                }
                $tool = Resolve-ArchiveTool @('tar.exe', 'tar')
                $flag = Get-TarCreateFlag -Format $format
                $leafNames = foreach ($path in $items) { (Get-Item -LiteralPath $path -Force).Name }
                $arguments = @("-c$($flag)f", $archivePath, '--')
                $arguments += $leafNames
                Invoke-ArchiveTool -FilePath $tool -Arguments $arguments -WorkingDirectory $parent
            }
        }
        $archivePath
        """#
    )

    static let zipExtract = PowerShellScript.prelude(
        operationBody: #"""
        param($Arguments)
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        \#(commonHelpers)
        \#(extractionHelpers)

        $archivePath = (Get-Item -LiteralPath $Arguments.archive -Force).FullName
        $parent = [System.IO.Path]::GetDirectoryName($archivePath)
        $tempDirectory = New-ExtractTempDirectory -Parent $parent
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $tempDirectory)
            Materialize-ExtractionResult -TempDirectory $tempDirectory -ArchivePath $archivePath -Format 'zip'
        } catch {
            Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }
        """#
    )

    static let externalExtract = PowerShellScript.prelude(
        operationBody: #"""
        param($Arguments)
        \#(commonHelpers)
        \#(externalToolHelpers)
        \#(extractionHelpers)

        $archivePath = (Get-Item -LiteralPath $Arguments.archive -Force).FullName
        $parent = [System.IO.Path]::GetDirectoryName($archivePath)
        $tempDirectory = New-ExtractTempDirectory -Parent $parent
        $format = [string]$Arguments.format
        try {
            switch ($format) {
                'zip' {
                    $tool = Resolve-ArchiveTool @('7z.exe', '7z')
                    $arguments = @('x', '-y', "-o$tempDirectory")
                    if (-not [string]::IsNullOrEmpty($Arguments.password)) {
                        $arguments += "-p$($Arguments.password)"
                    }
                    $arguments += $archivePath
                    Invoke-ArchiveTool -FilePath $tool -Arguments $arguments -WorkingDirectory $null
                }
                'sevenZ' {
                    $tool = Resolve-ArchiveTool @('7z.exe', '7z')
                    $arguments = @('x', '-y', "-o$tempDirectory")
                    if (-not [string]::IsNullOrEmpty($Arguments.password)) {
                        $arguments += "-p$($Arguments.password)"
                    }
                    $arguments += $archivePath
                    Invoke-ArchiveTool -FilePath $tool -Arguments $arguments -WorkingDirectory $null
                }
                default {
                    if (-not [string]::IsNullOrEmpty($Arguments.password)) {
                        throw "Password-protected TAR archives are not supported."
                    }
                    $tool = Resolve-ArchiveTool @('tar.exe', 'tar')
                    $flag = Get-TarExtractFlag -Format $format
                    Invoke-ArchiveTool -FilePath $tool -Arguments @("-x$($flag)f", $archivePath, '-C', $tempDirectory) -WorkingDirectory $null
                }
            }
            Materialize-ExtractionResult -TempDirectory $tempDirectory -ArchivePath $archivePath -Format $format
        } catch {
            Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }
        """#
    )

    static let commonHelpers = #"""
    function Get-ArchiveParent($Items) {
        $itemsArray = @($Items)
        if ($itemsArray.Count -eq 0) { throw "No items selected for archive." }
        $firstItem = Get-Item -LiteralPath $itemsArray[0] -Force
        [System.IO.Path]::GetDirectoryName($firstItem.FullName)
    }

    function Assert-ArchiveName([string]$BaseName) {
        if ([string]::IsNullOrWhiteSpace($BaseName)) { throw "Archive name cannot be empty." }
        if ($BaseName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Archive name contains invalid characters: $BaseName"
        }
    }

    function New-UniqueArchivePath([string]$Directory, [string]$BaseName, [string]$Extension) {
        Assert-ArchiveName -BaseName $BaseName
        $attempt = 1
        while ($true) {
            $suffix = if ($attempt -eq 1) { '' } else { " $attempt" }
            $name = "$BaseName$suffix.$Extension"
            $candidate = Join-Path -Path $Directory -ChildPath $name
            if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
            $attempt += 1
        }
    }

    function New-UniqueChildPath([string]$Directory, [string]$Name) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
        $extension = [System.IO.Path]::GetExtension($Name)
        $attempt = 1
        while ($true) {
            $suffix = if ($attempt -eq 1) { '' } else { " $attempt" }
            $candidateName = "$baseName$suffix$extension"
            $candidate = Join-Path -Path $Directory -ChildPath $candidateName
            if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
            $attempt += 1
        }
    }

    function Get-ArchiveExtension([string]$Format) {
        switch ($Format) {
            'zip' { 'zip' }
            'sevenZ' { '7z' }
            'tarGz' { 'tar.gz' }
            'tarBz2' { 'tar.bz2' }
            'tarXz' { 'tar.xz' }
            default { throw "Unsupported archive format: $Format" }
        }
    }
    """#

    static let zipHelpers = #"""
    function Get-RelativeArchiveName([string]$Base, [string]$Path) {
        $separator = [string][System.IO.Path]::DirectorySeparatorChar
        $baseFull = [System.IO.Path]::GetFullPath($Base)
        if (-not $baseFull.EndsWith($separator)) { $baseFull += $separator }
        $baseUri = New-Object System.Uri -ArgumentList @($baseFull)
        $pathUri = New-Object System.Uri -ArgumentList @([System.IO.Path]::GetFullPath($Path))
        [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString())
    }

    function Add-ZipItem($Archive, $Item, [string]$Root) {
        $entryName = Get-RelativeArchiveName -Base $Root -Path $Item.FullName
        if ($Item.PSIsContainer) {
            if (-not $entryName.EndsWith('/')) { $entryName += '/' }
            $Archive.CreateEntry($entryName) | Out-Null
            Get-ChildItem -LiteralPath $Item.FullName -Force | ForEach-Object {
                Add-ZipItem -Archive $Archive -Item $_ -Root $Root
            }
            return
        }

        if ([int64]$Item.Length -gt [uint32]::MaxValue) {
            throw "Built-in ZIP cannot archive entries larger than 4 GiB without a host 7z tool: $($Item.FullName)"
        }
        $entry = $Archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        $fileStream = [System.IO.File]::Open($Item.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $fileStream.CopyTo($entryStream)
        } finally {
            $fileStream.Dispose()
            $entryStream.Dispose()
        }
    }
    """#

    static let externalToolHelpers = #"""
    function Resolve-ArchiveTool($Names) {
        foreach ($name in $Names) {
            $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $command) { return $command.Source }
        }
        throw "Required archive tool is not available on the Windows host: $($Names -join ', ')"
    }

    function Invoke-ArchiveTool([string]$FilePath, [object[]]$Arguments, [string]$WorkingDirectory) {
        $pushed = $false
        if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushed = $true
        }
        try {
            $output = & $FilePath @Arguments 2>&1
            $status = $LASTEXITCODE
        } finally {
            if ($pushed) { Pop-Location }
        }
        if ($status -ne 0) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrEmpty($message)) { $message = "$FilePath failed with exit code $status." }
            throw $message
        }
    }

    function Get-TarCreateFlag([string]$Format) {
        switch ($Format) {
            'tarGz' { 'z' }
            'tarBz2' { 'j' }
            'tarXz' { 'J' }
            default { throw "Unsupported tar archive format: $Format" }
        }
    }

    function Get-TarExtractFlag([string]$Format) {
        switch ($Format) {
            'tarGz' { 'z' }
            'tarBz2' { 'j' }
            'tarXz' { 'J' }
            default { throw "Unsupported tar archive format: $Format" }
        }
    }
    """#

    static let extractionHelpers = #"""
    function New-ExtractTempDirectory([string]$Parent) {
        $path = Join-Path -Path $Parent -ChildPath ".detours-extract-$([guid]::NewGuid().ToString())"
        New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
        $path
    }

    function Get-ArchiveBaseName([string]$ArchivePath, [string]$Format) {
        $name = [System.IO.Path]::GetFileName($ArchivePath)
        $lower = $name.ToLowerInvariant()
        foreach ($suffix in @('.tar.gz', '.tar.bz2', '.tar.xz', '.tgz', '.tbz2', '.txz', '.zip', '.7z')) {
            if ($lower.EndsWith($suffix)) { return $name.Substring(0, $name.Length - $suffix.Length) }
        }
        [System.IO.Path]::GetFileNameWithoutExtension($name)
    }

    function Materialize-ExtractionResult([string]$TempDirectory, [string]$ArchivePath, [string]$Format) {
        $items = @(Get-ChildItem -LiteralPath $TempDirectory -Force)
        if ($items.Count -eq 0) { throw "Archive appears to be empty: $ArchivePath" }
        $parent = [System.IO.Path]::GetDirectoryName($ArchivePath)

        if ($items.Count -eq 1) {
            $destination = New-UniqueChildPath -Directory $parent -Name $items[0].Name
            Move-Item -LiteralPath $items[0].FullName -Destination $destination -ErrorAction Stop
            Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
            return (Get-Item -LiteralPath $destination -Force).FullName
        }

        $wrapperName = Get-ArchiveBaseName -ArchivePath $ArchivePath -Format $Format
        $wrapper = New-UniqueChildPath -Directory $parent -Name $wrapperName
        New-Item -ItemType Directory -Path $wrapper -ErrorAction Stop | Out-Null
        foreach ($item in $items) {
            Move-Item -LiteralPath $item.FullName -Destination (Join-Path -Path $wrapper -ChildPath $item.Name) -ErrorAction Stop
        }
        Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        (Get-Item -LiteralPath $wrapper -Force).FullName
    }
    """#
}
