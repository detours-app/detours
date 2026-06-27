import Foundation

extension WindowsRemoteProvider {
    static let homeDirectoryScript = PowerShellScript.prelude(
        operationBody: """
        [Environment]::GetFolderPath('UserProfile')
        """
    )

    static let driveListScript = PowerShellScript.prelude(
        operationBody: """
        Get-PSDrive -PSProvider FileSystem | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Root = $_.Root
                Free = if ($null -eq $_.Free) { $null } else { [int64]$_.Free }
                Used = if ($null -eq $_.Used) { $null } else { [int64]$_.Used }
            }
        }
        """
    )

    static let listScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        function Convert-Item($Item) {
            [pscustomobject]@{
                Name = $Item.Name
                FullName = $Item.FullName
                PSIsContainer = [bool]$Item.PSIsContainer
                Attributes = $Item.Attributes.ToString()
                Length = if ($Item.PSIsContainer) { $null } else { [int64]$Item.Length }
                LastWriteTimeUtc = [int64]([DateTimeOffset]$Item.LastWriteTimeUtc).ToUnixTimeMilliseconds()
            }
        }

        Get-ChildItem -LiteralPath $Arguments.path -Force | Where-Object {
            [bool]$Arguments.showHidden -or -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)
        } | ForEach-Object { Convert-Item $_ }
        """
    )

    static let statScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        [pscustomobject]@{
            Name = $item.Name
            FullName = $item.FullName
            PSIsContainer = [bool]$item.PSIsContainer
            Attributes = $item.Attributes.ToString()
            Length = if ($item.PSIsContainer) { $null } else { [int64]$item.Length }
            LastWriteTimeUtc = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        }
        """
    )

    static let createDirectoryScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        if ($Arguments.intermediate) {
            [System.IO.Directory]::CreateDirectory($Arguments.path) | Out-Null
        } else {
            New-Item -ItemType Directory -Path $Arguments.path -ErrorAction Stop | Out-Null
        }
        $Arguments.path
        """
    )

    static let renameScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        $parent = [System.IO.Path]::GetDirectoryName($item.FullName)
        $destination = Join-Path -Path $parent -ChildPath $Arguments.newName
        Rename-Item -LiteralPath $item.FullName -NewName $Arguments.newName -ErrorAction Stop
        (Get-Item -LiteralPath $destination -Force).FullName
        """
    )

    static let copyScript = transferScript(
        verb: "copy",
        itemCommand: "Copy-Item -LiteralPath $sourceItem.FullName -Destination $target -Recurse -Force -ErrorAction Stop"
    )

    static let moveScript = transferScript(
        verb: "move",
        itemCommand: "Move-Item -LiteralPath $sourceItem.FullName -Destination $target -Force -ErrorAction Stop"
    )

    private static func transferScript(verb: String, itemCommand: String) -> String {
        PowerShellScript.prelude(
            operationBody: """
            param($Arguments)
            foreach ($source in $Arguments.sources) {
                $sourceItem = Get-Item -LiteralPath $source -Force
                $target = Join-Path -Path $Arguments.destination -ChildPath $sourceItem.Name
                if ([string]::Equals($sourceItem.FullName, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Cannot \(verb) an item onto itself: $($sourceItem.FullName)"
                }
                if (Test-Path -LiteralPath $target) {
                    throw "Destination already exists: $target"
                }
                \(itemCommand)
                (Get-Item -LiteralPath $target -Force).FullName
            }
            """
        )
    }

    static let copyItemScript = itemTransferScript(
        itemCommand: "Copy-Item -LiteralPath $sourceItem.FullName -Destination $Arguments.target -Recurse -Force -ErrorAction Stop"
    )

    static let moveItemScript = itemTransferScript(
        itemCommand: "Move-Item -LiteralPath $sourceItem.FullName -Destination $Arguments.target -Force -ErrorAction Stop"
    )

    // Copy/move a single item to an explicit, fully-qualified target path, refusing to
    // overwrite an existing target. The file operation queue resolves same-name
    // collisions (Skip/Replace/Keep Both) before staging anything here, so a target is
    // never silently clobbered inside the script.
    private static func itemTransferScript(itemCommand: String) -> String {
        PowerShellScript.prelude(
            operationBody: """
            param($Arguments)
            $sourceItem = Get-Item -LiteralPath $Arguments.source -Force
            if ([string]::Equals($sourceItem.FullName, $Arguments.target, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Cannot transfer an item onto itself: $($sourceItem.FullName)"
            }
            if (Test-Path -LiteralPath $Arguments.target) {
                throw "Destination already exists: $($Arguments.target)"
            }
            \(itemCommand)
            (Get-Item -LiteralPath $Arguments.target -Force).FullName
            """
        )
    }

    static let trashScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        \(recycleBinHelpers)

        foreach ($path in $Arguments.paths) {
            $item = Get-Item -LiteralPath $path -Force
            $originalPath = $item.FullName
            $trashPath = Send-ToRecycleBin -Path $originalPath
            $token = ConvertTo-Base64UrlJson @{
                OriginalPath = $originalPath
                TrashPath = $trashPath
            }
            [pscustomobject]@{
                OriginalPath = $originalPath
                TrashToken = $token
            }
        }
        """
    )

    static let restoreTrashScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        \(recycleBinHelpers)

        foreach ($entry in $Arguments.items) {
            $token = ConvertFrom-Base64UrlJson -Token $entry.trashToken
            if (Test-Path -LiteralPath $entry.originalPath) {
                throw "Restore destination already exists: $($entry.originalPath)"
            }
            $trashPath = [string]$token.TrashPath
            if ([string]::IsNullOrWhiteSpace($trashPath) -or -not (Test-Path -LiteralPath $trashPath)) {
                throw "Could not find matching trash item for: $($entry.originalPath)"
            }

            $parent = [System.IO.Path]::GetDirectoryName([string]$entry.originalPath)
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                [System.IO.Directory]::CreateDirectory($parent) | Out-Null
            }
            Move-Item -LiteralPath $trashPath -Destination $entry.originalPath -Force -ErrorAction Stop
            $entry.originalPath
        }
        """
    )

    static let folderSizeScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        if (-not $item.PSIsContainer) { [int64]$item.Length; return }
        $sum = (Get-ChildItem -LiteralPath $Arguments.path -Force -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { [int64]0 } else { [int64]$sum }
        """
    )

    static let readSymlinkScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        if ($item.Target) {
            if ($item.Target -is [array]) { $item.Target[0] } else { $item.Target }
        } else {
            $item.FullName
        }
        """
    )

    static let versionScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        $hash = if ($item.PSIsContainer) { '' } else { (Get-FileHash -LiteralPath $Arguments.path -Algorithm SHA256).Hash.ToLowerInvariant() }
        [pscustomobject]@{
            SHA256 = $hash
            LastWriteTimeUtc = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        }
        """
    )

    static let recycleBinHelpers = """
    function Get-DetoursTrashRoot {
        $profile = [Environment]::GetFolderPath('UserProfile')
        if ([string]::IsNullOrWhiteSpace($profile)) { throw "Windows user profile is unavailable." }
        $root = Join-Path -Path $profile -ChildPath '.detours-trash'
        [System.IO.Directory]::CreateDirectory($root) | Out-Null
        $root
    }

    function New-DetoursTrashPath([string]$Name) {
        $root = Get-DetoursTrashRoot
        while ($true) {
            $candidate = Join-Path -Path $root -ChildPath "$([guid]::NewGuid().ToString())-$Name"
            if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        }
    }

    function Send-ToRecycleBin([string]$Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $trashPath = New-DetoursTrashPath -Name $item.Name
        Move-Item -LiteralPath $item.FullName -Destination $trashPath -Force -ErrorAction Stop
        $trashPath
    }

    function ConvertTo-Base64UrlJson($Value) {
        $json = $Value | ConvertTo-Json -Compress -Depth 6
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json)).
            TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }

    function ConvertFrom-Base64UrlJson([string]$Token) {
        $base64 = $Token.Replace('-', '+').Replace('_', '/')
        switch ($base64.Length % 4) {
            0 { break }
            2 { $base64 += '==' }
            3 { $base64 += '=' }
            default { throw "Invalid Windows trash token." }
        }
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64)) | ConvertFrom-Json
    }
    """
}
