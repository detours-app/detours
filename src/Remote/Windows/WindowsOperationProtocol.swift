import Foundation
import RemoteOperationSupport

struct WindowsOperationArguments: Encodable {
    private enum Key: String, CodingKey { case prepareIngress, sealIngress, identity = "_0" }

    enum Request: Encodable {
        case shared(OperationRequest)
        case prepareIngress(OperationRequestIdentity)
        case sealIngress(OperationRequestIdentity)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .shared(let request): try request.encode(to: encoder)
            case .prepareIngress(let identity), .sealIngress(let identity):
                let key: Key
                if case .prepareIngress = self { key = .prepareIngress } else { key = .sealIngress }
                var container = encoder.container(keyedBy: Key.self)
                var value = container.nestedContainer(keyedBy: Key.self, forKey: key)
                try value.encode(identity, forKey: .identity)
            }
        }
    }

    let request: Request
    let canonicalIntent: Data?

    init(_ request: OperationRequest) throws {
        self.request = .shared(request)
        if case .accept(_, let intent) = request { canonicalIntent = try intent.canonicalData() } else { canonicalIntent = nil }
    }

    init(ingress request: Request) {
        self.request = request
        self.canonicalIntent = nil
    }
}

extension WindowsOperationScripts {
    static let protocolScript = PowerShellScript.prelude(operationBody: #"""
    param($Arguments)
    \#(filesystemHelpers)
    \#(journalHelpers)
    \#(requestHelpers)
    \#(mutationHelpers)
    \#(ingressHelpers)
    \#(trashHelpers)
    \#(restoreHelpers)
    \#(replacementHelpers)
    \#(backupHandoffHelpers)
    \#(treeProofHelpers)
    \#(treeCopyHelpers)
    \#(archiveHelpers)
    \#(zipPlanHelpers)
    \#(zipExtractionHelpers)
    \#(deletionHelpers)
    \#(WindowsArchiveScripts.externalToolHelpers)
    \#(archiveProcessHelpers)
    \#(tarCreationHelpers)
    \#(tarReaderHelpers)
    \#(tarExtractionHelpers)
    \#(tarLinkHelpers)
    \#(sevenZipRuntimeHelpers)
    \#(sevenZipExtractionHelpers)
    $profile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($profile)) { throw 'Windows user profile is unavailable.' }
    $machine = [Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography', 'MachineGuid', $null)
    if ([string]::IsNullOrWhiteSpace($machine)) { throw 'Windows machine identity is unavailable.' }
    $account = [pscustomobject]@{
        hostIdentity = ([guid]$machine).ToString('D')
        accountIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    Invoke-WindowsOperation (Join-Path $profile '.detours-operations') $account $Arguments.request $Arguments.canonicalIntent
    """#)

    static let requestHelpers = #"""
    function Get-WindowsContentProof([string]$Path) {
        [DetoursOperationFiles]::Prove($Path)
    }
    function Get-OperationPath($Location, $Account) {
        if ($Location.account.hostIdentity -cne $Account.hostIdentity -or
            $Location.account.accountIdentity -cne $Account.accountIdentity) { throw 'Operation location account mismatch.' }
        $path = [string]$Location.path.windows._0
        if ($path.Length -lt 3 -or -not [char]::IsLetter($path[0]) -or $path[1] -ne ':' -or [int]$path[2] -ne 92 -or $path.Substring(2).Contains(':') -or
            @($path.Split([char[]]@(92, 47)) | Where-Object { $_ -eq '..' }).Count -gt 0) { throw 'Invalid Windows operation path.' }
        [System.IO.Path]::GetFullPath($path)
    }
    function Get-WindowsOperationLocation([string]$Path, $Account) {
        [pscustomobject]@{ account = $Account; path = @{ windows = @{ _0 = $Path } } }
    }
    function Get-WindowsOperationLookup([string]$Path) {
        try { return @{ found = @{ _0 = [DetoursOperationFiles]::Observe($Path) } } }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -is [System.ComponentModel.Win32Exception]) {
                switch ($cause.NativeErrorCode) {
                    { $_ -in @(2, 3) } { return @{ missing = @{} } }
                    5 { return @{ denied = @{} } }
                    { $_ -in @(53, 64, 67, 1231) } { return @{ disconnected = @{} } }
                    50 { return @{ unsupported = @{} } }
                }
            }
            if ($cause -is [System.NotSupportedException]) { return @{ unsupported = @{} } }
            throw
        }
    }
    function Assert-WindowsObservation($Actual, $Expected) {
        if ($Actual.identity.volume -cne $Expected.identity.volume -or $Actual.identity.object -cne $Expected.identity.object -or
            $Actual.kind -cne $Expected.kind -or $Actual.version -cne $Expected.version -or
            $Actual.linkTarget -cne $Expected.linkTarget -or ($null -ne $Expected.sha256 -and $Actual.sha256 -cne $Expected.sha256)) {
            throw 'Operation object changed.'
        }
    }
    function Read-WindowsOperation($Root, $Identity, $Account, $Epoch) {
        $record = Read-OperationSnapshot $Root $Identity.id $Account $Epoch
        if ($record.intentDigest -cne $Identity.intentDigest) { throw 'Operation intent mismatch.' }
        $record
    }
    function Invoke-WindowsOperation([string]$Root, $Account, $Request, [string]$CanonicalIntent) {
        $Root = Open-OperationDirectory $Root
        $epoch = Open-OperationEpoch $Root $Account
        $properties = @($Request.PSObject.Properties)
        if ($properties.Count -ne 1) { throw 'Invalid operation request.' }
        $kind = $properties[0].Name
        $parameters = $properties[0].Value
        if ($kind -eq 'handshake') {
            if ($parameters.version -ne 2) { return @{ incompatible = @{ _0 = @{ protocolVersion = @{ expected = 2; actual = $parameters.version } } } } }
            if ($parameters.schemaVersion -ne 1) { return @{ incompatible = @{ _0 = @{ journalSchema = @{ expected = 1; actual = $parameters.schemaVersion } } } } }
            $capabilities = @('receipts', 'status', 'cancellation', 'ownedTemporaryObjects', 'nonReplacingCommit')
            $missing = @($parameters.requiredCapabilities | Where-Object { $_ -notin $capabilities })
            if ($missing.Count -gt 0) { return @{ incompatible = @{ _0 = @{ missingCapabilities = @{ _0 = $missing } } } } }
            return @{ handshake = @{ _0 = @{ version = 2; schemaVersion = 1; capabilities = $capabilities; account = $Account; epoch = $epoch } } }
        }
        if ($kind -eq 'lookup') {
            return @{ lookup = @{ _0 = (Get-WindowsOperationLookup (Get-OperationPath $parameters._0 $Account)) } }
        }
        $identity = if ($null -ne $parameters.identity) { $parameters.identity } else { $parameters._0 }
        if ($identity.account.hostIdentity -cne $Account.hostIdentity -or $identity.account.accountIdentity -cne $Account.accountIdentity) {
            return @{ incompatible = @{ _0 = @{ accountMismatch = @{} } } }
        }
        if ([guid]$identity.epoch -ne [guid]$epoch) { return @{ incompatible = @{ _0 = @{ epochChanged = @{} } } } }
        $key = Get-OperationKey $identity.id
        if ($kind -eq 'cancel') {
            Read-WindowsOperation $Root $identity $Account $epoch | Out-Null
            Cancel-Operation $Root $identity.id
            return @{ cancellationRecorded = @{ _0 = $identity } }
        }
        if ($kind -eq 'execute') {
            $accepted = Read-WindowsOperation $Root $identity $Account $epoch
            if ($accepted.intent.action -eq 'restore') {
                return @{ receipt = @{ _0 = (Invoke-WindowsRestoreRequest $Root $identity $Account $epoch) } }
            }
        }
        $lockPath = Join-Path $Root ($key + '.lock')
        if ($kind -eq 'status') {
            $record = Read-WindowsOperation $Root $identity $Account $epoch
            try { $ownership = [System.IO.FileStream]::new($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
            catch [System.IO.IOException] {
                if (($_.Exception.HResult -band 65535) -notin @(32, 33)) { throw }
                return @{ status = @{ _0 = $record } }
            }
        } else { $ownership = Lock-OperationFile $lockPath '' }
        try {
            if ($kind -eq 'accept') {
                $bytes = [Convert]::FromBase64String($CanonicalIntent)
                $hash = [System.Security.Cryptography.SHA256]::Create()
                try { $digest = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
                finally { $hash.Dispose() }
                if ($digest -cne $identity.intentDigest) { throw 'Operation intent digest mismatch.' }
                $intent = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
                if ((Get-OperationKey $intent.id) -cne $key) { throw 'Operation item identity mismatch.' }
                if ($intent.action -notin @('copy', 'editorUpload', 'rename', 'move', 'createFolder', 'trash', 'restore', 'archiveCreate', 'archiveExtract', 'permanentDelete')) {
                    throw 'This Windows operation action is not implemented.'
                }
                return @{ accepted = @{ _0 = (Accept-Operation $Root $intent $digest $Account $epoch $ownership) } }
            }
            $record = Read-WindowsOperation $Root $identity $Account $epoch
            $context = @{ root = $Root; account = $Account; epoch = $epoch; identity = $identity; ownership = $ownership; record = $record }
            if ($kind -eq 'status') {
                Resolve-WindowsOperation $context
                return @{ status = @{ _0 = (Read-WindowsOperation $Root $identity $Account $epoch) } }
            }
            if ($kind -eq 'acknowledge') {
                Confirm-OperationResult $Root $identity.id $Account $epoch ([bool]$parameters.retainingUndo) $ownership | Out-Null
                return @{ acknowledged = @{ _0 = $identity } }
            }
            if ($kind -in @('prepareIngress', 'sealIngress')) {
                return @{ receipt = @{ _0 = (Invoke-WindowsIngress $context $kind) } }
            }
            return @{ receipt = @{ _0 = (Invoke-WindowsMutation $context $kind $parameters) } }
        } finally { $ownership.Dispose() }
    }
    """#
}
