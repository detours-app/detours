import Foundation

extension WindowsOperationScripts {
    static let tarCreationHelpers = #"""
    function Prepare-WindowsTarArchive($Context, $Parameters) {
        $intent = $Context.record.intent
        if ($intent.action -ne 'archiveCreate' -or $intent.archiveFormat -notin @('tarGz', 'tarBz2', 'tarXz') -or
            @($intent.sources).Count -eq 0 -or @($intent.sources).Count -ne @($intent.sourceObservations).Count) {
            throw 'Invalid accepted TAR creation.'
        }
        if ($intent.archiveEncrypted -ne $false -or -not [string]::IsNullOrEmpty($Parameters.password)) {
            throw 'Password-protected archives are not supported on Windows remote machines.'
        }
        $tool = Resolve-ArchiveTool @('tar.exe', 'tar')
        $destination = Assert-WindowsDestination $Context
        $destinationParent = [DetoursOperationFiles]::Observe([System.IO.Path]::GetDirectoryName($destination))
        $sources = @(); $names = @(); $parent = $null
        for ($index = 0; $index -lt @($intent.sources).Count; $index++) {
            Assert-WindowsOperationActive $Context
            $path = Get-OperationPath $intent.sources[$index] $Context.account
            $sourceParent = [System.IO.Path]::GetDirectoryName($path)
            if ($null -eq $parent) { $parent = $sourceParent }
            elseif (-not [string]::Equals($parent, $sourceParent, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Archive selections must share one parent directory.'
            }
            $manifest = Get-WindowsTreeProof $path
            $root = $manifest.entries[0].observation
            $observed = if ($root.kind -eq 'file') { $root } else { Get-WindowsManifestObservation $manifest }
            Assert-WindowsObservation $observed $intent.sourceObservations[$index]
            foreach ($entry in $manifest.entries) {
                if ($entry.observation.identity.volume -ceq $destinationParent.identity.volume -and
                    $entry.observation.identity.object -ceq $destinationParent.identity.object) { throw 'Cannot create an archive inside its source.' }
            }
            $sources += @{ location = $intent.sources[$index]; manifest = $manifest }
            $names += [System.IO.Path]::GetFileName($path)
        }
        $Context.record | Add-Member -NotePropertyName windowsArchiveSources -NotePropertyValue $sources -Force
        Save-WindowsWorkspace $Context
        New-WindowsWorkspace $Context $destination | Out-Null
        $output = New-WindowsPayload $Context
        try {
            $flag = Get-TarCompressionFlag $intent.archiveFormat
            $command = @("-c$($flag)f", '-', '--') + $names
            Write-WindowsArchiveProcess $Context $tool $command $parent $output
            $output.Flush($true)
        } finally { $output.Dispose() }
        foreach ($source in $sources) {
            Assert-WindowsOperationActive $Context
            $after = Get-WindowsTreeProof (Get-OperationPath $source.location $Context.account)
            Assert-WindowsTreeMovement $source.manifest $after
            for ($index = 0; $index -lt @($after.entries).Count; $index++) {
                Assert-WindowsObservation $after.entries[$index].observation $source.manifest.entries[$index].observation
            }
        }
        $payload = Join-Path $Context.record.windowsWorkspacePath 'payload'
        $observed = Get-WindowsContentProof $payload
        if ($null -ne $intent.payloadProof -and ($observed.sha256 -cne $intent.payloadProof.sha256 -or $observed.byteCount -ne $intent.payloadProof.byteCount)) {
            throw 'Prepared archive does not match its accepted proof.'
        }
        Assert-WindowsOperationActive $Context
        $receipt = New-WindowsReceipt $Context 'readyToCommit' 'running'
        $receipt.preparedPayload = @{ location = (Get-WindowsOperationLocation $payload $Context.account); observation = $observed }
        $receipt.contentVerified = $true
        Save-WindowsReceipt $Context $receipt
    }
    """#
}
