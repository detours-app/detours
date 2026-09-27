import Foundation

enum WindowsOperationScripts {
    static let journalHelpers = #"""
    function Get-OperationKey($Id) {
        ([guid]::Parse([string]$Id.operation)).ToString('D') + '-' + ([guid]::Parse([string]$Id.item)).ToString('D')
    }

    function Open-OperationDirectory([string]$Root) {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [System.Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $security.AddAccessRule($rule)
        $directory = [System.IO.DirectoryInfo]::new($Root)
        if (-not $directory.Exists) { $directory.Create($security) }
        $directory.Refresh()
        if ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Unsafe journal directory.' }
        $actual = $directory.GetAccessControl()
        if ($actual.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or
            -not $actual.AreAccessRulesProtected) { throw 'Journal directory is not private.' }
        foreach ($entry in $actual.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($entry.AccessControlType -eq 'Allow' -and $entry.IdentityReference.Value -ne $sid.Value) {
                throw 'Journal directory grants access to another account.'
            }
        }
        $directory.FullName
    }

    function Lock-OperationFile([string]$Path, [string]$CancellationPath) {
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ($CancellationPath -and $null -ne (Read-OperationFile $CancellationPath)) { throw 'Operation cancelled.' }
            try {
                return [System.IO.FileStream]::new($Path, 'OpenOrCreate', 'ReadWrite', 'None')
            } catch [System.IO.IOException] {
                $code = $_.Exception.HResult -band 65535
                if ($code -ne 32 -and $code -ne 33) { throw }
                if ($clock.ElapsedMilliseconds -ge 10000) { throw 'Operation busy.' }
                [System.Threading.Thread]::Sleep(20)
            }
        }
    }

    function Read-OperationFile([string]$Path) {
        try { $stream = [System.IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite,Delete') }
        catch [System.IO.FileNotFoundException] { return $null }
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if ([string]::IsNullOrWhiteSpace($text)) { throw 'Empty operation record.' }
            $text | ConvertFrom-Json -ErrorAction Stop
        } finally { $stream.Dispose() }
    }

    function Write-OperationFile([string]$Path, $Value) {
        $parent = [System.IO.Path]::GetDirectoryName($Path)
        $temporary = Join-Path $parent ([guid]::NewGuid().ToString('D') + '.snapshot')
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Compress -Depth 100))
        $stream = [System.IO.FileStream]::new($temporary, 'CreateNew', 'Write', 'None')
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [System.IO.File]::Move($temporary, $Path) }
    }

    function Open-OperationEpoch([string]$Root, $Account) {
        $ownership = Lock-OperationFile (Join-Path $Root 'epoch.lock') ''
        try {
            $path = Join-Path $Root 'epoch.json'
            $record = Read-OperationFile $path
            if ($null -eq $record) {
                $record = [pscustomobject]@{ schemaVersion = 1; epoch = [guid]::NewGuid().ToString('D'); account = $Account }
                Write-OperationFile $path $record
            }
            if ($record.schemaVersion -ne 1) { throw 'Incompatible operation journal schema.' }
            if ($record.account.hostIdentity -cne $Account.hostIdentity -or
                $record.account.accountIdentity -cne $Account.accountIdentity) { throw 'Operation account mismatch.' }
            $record.epoch
        } finally { $ownership.Dispose() }
    }

    function Read-OperationSnapshot([string]$Root, $Id, $Account, [string]$Epoch) {
        $record = Read-OperationFile (Join-Path $Root ((Get-OperationKey $Id) + '.json'))
        if ($null -eq $record) { throw 'Operation record missing; result is unknown.' }
        if ($record.schemaVersion -ne 1) { throw 'Incompatible operation journal schema.' }
        if ((Get-OperationKey $record.id) -ne (Get-OperationKey $Id) -or
            $record.account.hostIdentity -cne $Account.hostIdentity -or
            $record.account.accountIdentity -cne $Account.accountIdentity) { throw 'Operation identity mismatch.' }
        if ([guid]$record.epoch -ne [guid]$Epoch) { throw 'Operation journal epoch changed; result is unknown.' }
        $record
    }

    function Assert-OperationOwnership([string]$Root, $Id, $Ownership) {
        $expected = Join-Path $Root ((Get-OperationKey $Id) + '.lock')
        if ($null -eq $Ownership -or $Ownership.SafeFileHandle.IsClosed -or $Ownership.Name -cne $expected) {
            throw 'Operation ownership mismatch.'
        }
    }

    function Accept-Operation([string]$Root, $Intent, [string]$Digest, $Account, [string]$Epoch, $Ownership) {
        Assert-OperationOwnership $Root $Intent.id $Ownership
        $key = Get-OperationKey $Intent.id
        $path = Join-Path $Root ($key + '.json')
        $previous = Read-OperationFile $path
        if ($null -ne $previous) {
            $previous = Read-OperationSnapshot $Root $Intent.id $Account $Epoch
            if ($previous.intentDigest -cne $Digest) { throw 'Operation intent mismatch.' }
            if ($null -ne $previous.intent -and ($previous.intent | ConvertTo-Json -Compress -Depth 100) -cne
                ($Intent | ConvertTo-Json -Compress -Depth 100)) { throw 'Operation intent changed.' }
            return $previous
        }
        if ($null -ne (Read-OperationFile (Join-Path $Root ($key + '.cancel')))) { throw 'Operation cancelled.' }
        $record = [pscustomobject]@{
            schemaVersion = 1; epoch = $Epoch; account = $Account; id = $Intent.id
            intentDigest = $Digest; revision = 1; intent = $Intent; receipt = $null; acknowledged = $false
        }
        Write-OperationFile $path $record
        $record
    }

    function Write-OperationReceipt([string]$Root, $Receipt, $Account, [string]$Epoch, $Ownership) {
        Assert-OperationOwnership $Root $Receipt.id $Ownership
        $record = Read-OperationSnapshot $Root $Receipt.id $Account $Epoch
        if ($record.acknowledged -or $null -eq $record.intent) { throw 'Operation has a retained terminal tombstone.' }
        if ($Receipt.schemaVersion -ne 1 -or [guid]$Receipt.epoch -ne [guid]$Epoch -or
            $Receipt.account.hostIdentity -cne $Account.hostIdentity -or
            $Receipt.account.accountIdentity -cne $Account.accountIdentity -or
            $Receipt.intentDigest -cne $record.intentDigest) { throw 'Operation receipt mismatch.' }
        if ($null -ne $record.receipt) {
            if ($Receipt.revision -lt $record.receipt.revision) { return $record }
            if ($Receipt.revision -eq $record.receipt.revision) {
                if (($Receipt | ConvertTo-Json -Compress -Depth 100) -cne
                    ($record.receipt | ConvertTo-Json -Compress -Depth 100)) { throw 'Conflicting receipt revision.' }
                return $record
            }
            if ($record.receipt.phase -eq 'terminal' -and
                $record.receipt.outcome -in @('committed', 'failedUnchanged') -and
                $record.receipt.outcome -ne $Receipt.outcome) { throw 'Terminal outcome changed.' }
        }
        if ($Receipt.outcome -eq 'failedUnchanged' -and
            (@($Receipt.effects).Count -ne 0 -or @($Receipt.recovery).Count -ne 0)) { throw 'Unchanged receipt retains effects.' }
        if ($Receipt.outcome -eq 'committed') {
            if ($record.intent.action -eq 'move' -and $Receipt.sourceDisposition -ne 'confirmed') { throw 'Move source is unconfirmed.' }
            foreach ($child in $Receipt.children) {
                if ($child.outcome -ne 'committed' -and -not $child.skipped) { throw 'Incomplete child result.' }
            }
        }
        $record.receipt = $Receipt
        $record.revision = [long]$record.revision + 1
        Write-OperationFile (Join-Path $Root ((Get-OperationKey $Receipt.id) + '.json')) $record
        $record
    }

    function Test-OperationCompactable($Receipt) {
        if ($null -eq $Receipt -or $Receipt.phase -ne 'terminal' -or
            $Receipt.outcome -notin @('committed', 'failedUnchanged') -or @($Receipt.recovery).Count -ne 0) { return $false }
        foreach ($child in $Receipt.children) { if (-not (Test-OperationCompactable $child)) { return $false } }
        $true
    }

    function Confirm-OperationResult([string]$Root, $Id, $Account, [string]$Epoch, [bool]$RetainingUndo, $Ownership) {
        Assert-OperationOwnership $Root $Id $Ownership
        $record = Read-OperationSnapshot $Root $Id $Account $Epoch
        if ($record.acknowledged) { return $record }
        if ($RetainingUndo -or -not (Test-OperationCompactable $record.receipt)) { throw 'Operation recovery or undo is outstanding.' }
        $record.intent = $null
        $record.acknowledged = $true
        $record.revision = [long]$record.revision + 1
        Write-OperationFile (Join-Path $Root ((Get-OperationKey $Id) + '.json')) $record
        $record
    }

    function Cancel-Operation([string]$Root, $Id) {
        Write-OperationFile (Join-Path $Root ((Get-OperationKey $Id) + '.cancel')) $Id
    }
    """#
}

extension WindowsRemoteProvider {
    static let smallFileWriteScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $bytes = [Convert]::FromBase64String([string]$Arguments.contentsBase64)
        [System.IO.File]::WriteAllBytes([string]$Arguments.path, $bytes)
        $item = Get-Item -LiteralPath $Arguments.path -Force
        if ([bool]$Arguments.hidden) {
            $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
        } else {
            $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden)
        }
        $item.FullName
        """
    )
}
