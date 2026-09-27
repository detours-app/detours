import Foundation

extension WindowsRemoteProvider {
    static let homeDirectoryScript = PowerShellScript.prelude(
        operationBody: """
        [Environment]::GetFolderPath('UserProfile')
        """
    )

    static let driveListScript = PowerShellScript.prelude(
        operationBody: """
        [System.IO.DriveInfo]::GetDrives() | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name.Substring(0, 1)
                Root = $_.RootDirectory.FullName
                Free = if ($_.IsReady) { [int64]$_.AvailableFreeSpace } else { $null }
                Used = if ($_.IsReady) { [int64]($_.TotalSize - $_.AvailableFreeSpace) } else { $null }
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

    static let smallFileReadScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$Arguments.path))
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

}
