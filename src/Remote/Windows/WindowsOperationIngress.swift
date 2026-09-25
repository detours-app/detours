import Foundation

extension WindowsOperationScripts {
    static let ingressHelpers = #"""
    function Invoke-WindowsIngress($Context, [string]$Kind) {
        $intent = $Context.record.intent
        if ($intent.action -notin @('copy', 'editorUpload') -or $null -eq $intent.payloadProof) { throw 'Invalid accepted ingress.' }
        if ($Context.record.receipt.phase -in @('terminal', 'readyToCommit')) { return $Context.record.receipt }
        if ($Kind -eq 'prepareIngress' -and $Context.record.windowsIngressReady) { return $Context.record.receipt }
        if ($Context.record.windowsIngressSealing) {
            Resolve-WindowsOperation $Context
            return $Context.record.receipt
        }
        try {
            Assert-WindowsOperationActive $Context
            $destination = Assert-WindowsNewDestination $Context
            if ($Kind -eq 'prepareIngress') {
                if ($null -ne $Context.record.receipt) { throw 'Operation preparation already started.' }
                $workspace = New-WindowsWorkspace $Context $destination
                $path = Join-Path $workspace 'ingress'
                $stream = [DetoursOperationFiles]::CreateNewFile($path)
                try {
                    $observed = [DetoursOperationFiles]::ObserveStream($stream)
                    $Context.record.workspace.objects = @(New-WindowsOwnedObject 'ingress' $observed)
                    $Context.record | Add-Member -NotePropertyName windowsIngressReady -NotePropertyValue $true -Force
                    Save-WindowsWorkspace $Context
                } finally { $stream.Dispose() }
                $receipt = New-WindowsReceipt $Context 'preparing' 'running'
                $receipt.preparedPayload = @{ location = (Get-WindowsOperationLocation $path $Context.account); observation = $observed }
                return Save-WindowsReceipt $Context $receipt
            }
            if (-not $Context.record.windowsIngressReady) { throw 'Operation ingress was not allocated.' }
            $path = Get-OperationPath $Context.record.receipt.preparedPayload.location $Context.account
            $expected = $Context.record.receipt.preparedPayload.observation
            $observed = [DetoursOperationFiles]::Observe($path)
            if ($observed.kind -ne 'file' -or $observed.identity.volume -cne $expected.identity.volume -or
                $observed.identity.object -cne $expected.identity.object) { throw 'Operation ingress changed identity.' }
            $Context.record | Add-Member -NotePropertyName windowsIngressSealing -NotePropertyValue $true -Force
            Save-WindowsWorkspace $Context
            $inputStream = [System.IO.FileStream]::new($path, 'Open', 'Read', 'ReadWrite,Delete')
            try {
                $opened = [DetoursOperationFiles]::ObserveStream($inputStream)
                Assert-WindowsObservation $opened $observed
                $output = New-WindowsPayload $Context
                try {
                    $buffer = [byte[]]::new(65536)
                    while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        Assert-WindowsOperationActive $Context
                        $output.Write($buffer, 0, $count)
                    }
                    $output.Flush($true)
                } finally { $output.Dispose() }
                Assert-WindowsObservation ([DetoursOperationFiles]::ObserveStream($inputStream)) $opened
            } finally { $inputStream.Dispose() }
            $payload = Join-Path $Context.record.windowsWorkspacePath 'payload'
            $proof = [DetoursOperationFiles]::Prove($payload)
            if ($proof.byteCount -ne $intent.payloadProof.byteCount -or $proof.sha256 -cne $intent.payloadProof.sha256) {
                throw 'Operation ingress content verification failed.'
            }
            Assert-WindowsOperationActive $Context
            $receipt = New-WindowsReceipt $Context 'readyToCommit' 'running'
            $receipt.preparedPayload = @{ location = (Get-WindowsOperationLocation $payload $Context.account); observation = $proof }
            $receipt.contentVerified = $true
            Save-WindowsReceipt $Context $receipt
        } catch {
            $failure = $_.Exception.Message
            $outcome = 'failedUnchanged'; $recovery = @()
            if ($null -ne $Context.record.workspace) {
                try { Remove-WindowsWorkspace $Context }
                catch { $outcome = 'partial'; $recovery = @($Context.record.receipt.recovery); $failure += '; cleanup: ' + $_.Exception.Message }
            } elseif ($null -ne $Context.record.receipt.plannedPaths) { $outcome = 'unknown' }
            $receipt = New-WindowsReceipt $Context 'terminal' $outcome
            $receipt.recovery = $recovery; $receipt.failure = $failure
            Save-WindowsReceipt $Context $receipt
        }
    }
    """#
}
