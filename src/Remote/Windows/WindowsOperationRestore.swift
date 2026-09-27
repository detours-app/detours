import Foundation

extension WindowsOperationScripts {
    static let restoreHelpers = #"""
    function Invoke-WindowsRestoreRequest($Root, $Identity, $Account, $Epoch) {
        $initial = Read-WindowsOperation $Root $Identity $Account $Epoch
        if ($initial.receipt.phase -eq 'terminal') { return $initial.receipt }
        $reversed = $initial.intent.reverses
        if ($null -eq $reversed) { throw 'Restore requires an accepted recovery reference.' }
        $key = Get-OperationKey $Identity.id
        $previousKey = Get-OperationKey $reversed
        if ($key -ceq $previousKey) { throw 'An operation cannot restore itself.' }
        $locks = @{}
        try {
            foreach ($itemKey in (@($key, $previousKey) | Sort-Object)) {
                $locks[$itemKey] = Lock-OperationFile (Join-Path $Root ($itemKey + '.lock')) (Join-Path $Root ($key + '.cancel'))
            }
            $record = Read-WindowsOperation $Root $Identity $Account $Epoch
            if ($record.receipt.phase -eq 'terminal') { return $record.receipt }
            $context = @{ root = $Root; account = $Account; epoch = $Epoch; identity = $Identity; ownership = $locks[$key]; record = $record }
            if ($null -ne $record.receipt) { Resolve-WindowsOperation $context; return $context.record.receipt }
            try {
                $previous = Read-OperationSnapshot $Root $reversed $Account $Epoch
                $intent = $record.intent
                if ($intent.action -ne 'restore' -or @($intent.sources).Count -ne 1 -or @($intent.sourceObservations).Count -ne 1 -or
                    @($intent.conflict.PSObject.Properties.Name) -notcontains 'createNew') { throw 'Invalid accepted restore.' }
                $source = Get-OperationPath $intent.sources[0] $Account
                $destination = Get-OperationPath $intent.destination $Account
                $references = @($previous.receipt.recovery | Where-Object {
                    $_.purpose -in @('sourceTrash', 'displacedOriginal') -and $null -ne $_.knownLocation -and $null -ne $_.original -and
                    (Get-OperationPath $_.knownLocation $Account) -ceq $source -and (Get-OperationPath $_.original $Account) -ceq $destination
                })
                if ($references.Count -ne 1 -or $previous.receipt.phase -ne 'terminal') { throw 'No confirmed recovery reference authorizes this restore.' }
                $reference = $references[0]
                $expected = $intent.sourceObservations[0]
                if ($reference.identity.volume -cne $expected.identity.volume -or $reference.identity.object -cne $expected.identity.object) {
                    throw 'Restore object identity does not match its recovery reference.'
                }
                $priorIdentity = @{ id = $reversed; account = $Account; epoch = $Epoch; intentDigest = $previous.intentDigest }
                $priorContext = @{ root = $Root; account = $Account; epoch = $Epoch; identity = $priorIdentity
                    ownership = $locks[$previousKey]; record = $previous }
                $result = Invoke-WindowsMutation $context 'execute' $null
                if ($result.outcome -ne 'committed') { return $result }
                try {
                    $commit = Lock-OperationFile (Join-Path $Root 'commit.lock') ''
                    try {
                        $directoryIdentity = $priorContext.record.windowsTrashDirectory.observation.identity
                        $workspaceIdentity = $priorContext.record.workspace.root.identity
                        $priorReceipt = $priorContext.record.receipt
                        $priorReceipt.revision = [long]$priorReceipt.revision + 1
                        $priorReceipt.recovery = @($priorReceipt.recovery | Where-Object {
                            -not ($_.purpose -eq $reference.purpose -and $_.identity.volume -ceq $reference.identity.volume -and
                                $_.identity.object -ceq $reference.identity.object)
                        })
                        Save-WindowsReceipt $priorContext $priorReceipt | Out-Null
                        Remove-WindowsTrashDirectory $priorContext
                        Remove-WindowsWorkspaceContents $priorContext
                        $priorReceipt = $priorContext.record.receipt
                        $priorReceipt.revision = [long]$priorReceipt.revision + 1
                        $priorReceipt.recovery = @($priorReceipt.recovery | Where-Object {
                            $emptyDirectory = $_.purpose -eq 'scratch' -and $_.identity.volume -ceq $directoryIdentity.volume -and
                                $_.identity.object -ceq $directoryIdentity.object
                            $emptyWorkspace = $_.purpose -eq 'scratch' -and $_.identity.volume -ceq $workspaceIdentity.volume -and
                                $_.identity.object -ceq $workspaceIdentity.object
                            -not ($emptyDirectory -or $emptyWorkspace)
                        })
                        Save-WindowsReceipt $priorContext $priorReceipt | Out-Null
                    } finally { $commit.Dispose() }
                } catch {
                    $receipt = New-WindowsReceipt $context 'terminal' 'committed'
                    $receipt.effects = @($result.effects); $receipt.sourceDisposition = 'confirmed'; $receipt.contentVerified = $result.contentVerified
                    $receipt.failure = 'Restored; recovery metadata cleanup was not confirmed: ' + $_.Exception.Message
                    $receipt.recovery = @($priorContext.record.receipt.recovery | Where-Object { $_.purpose -eq 'scratch' })
                    foreach ($cleanup in $receipt.recovery) { $cleanup.knownLocation = $null }
                    $directory = $priorContext.record.windowsTrashDirectory
                    if ($null -ne $directory -and @($receipt.recovery | Where-Object {
                        $_.identity.volume -ceq $directory.observation.identity.volume -and $_.identity.object -ceq $directory.observation.identity.object
                    }).Count -eq 0) {
                        $receipt.recovery = @($receipt.recovery) + @(@{ identity = $directory.observation.identity; purpose = 'scratch'; original = $null
                            knownLocation = $null; possibleLocations = @($directory.location) })
                    }
                    $result = Save-WindowsReceipt $context $receipt
                }
                $result
            } catch {
                if ($null -ne $context.record.receipt) { throw }
                $receipt = New-WindowsReceipt $context 'terminal' 'failedUnchanged'
                $receipt.sourceDisposition = 'unknown'; $receipt.failure = $_.Exception.Message
                Save-WindowsReceipt $context $receipt
            }
        } finally { foreach ($ownedLock in $locks.Values) { $ownedLock.Dispose() } }
    }
    """#
}
