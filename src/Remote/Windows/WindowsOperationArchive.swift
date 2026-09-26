import Foundation

extension WindowsOperationScripts {
    static let archiveHelpers = #"""
    function Prepare-WindowsArchive($Context, $Parameters) {
        $intent = $Context.record.intent
        if ($intent.action -ne 'archiveCreate' -or $intent.archiveFormat -ne 'zip') { throw 'Accepted Windows archive format is not implemented.' }
        if ($intent.archiveEncrypted -ne $false -or -not [string]::IsNullOrEmpty($Parameters.password)) {
            throw 'Password-protected archives are not supported on Windows remote machines.'
        }
        if (@($intent.sources).Count -eq 0 -or @($intent.sources).Count -ne @($intent.sourceObservations).Count) {
            throw 'Invalid accepted archive sources.'
        }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $destination = Assert-WindowsDestination $Context
        $parent = [DetoursOperationFiles]::Observe([System.IO.Path]::GetDirectoryName($destination))
        $sources = @(); $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        for ($index = 0; $index -lt @($intent.sources).Count; $index++) {
            Assert-WindowsOperationActive $Context
            $path = Get-OperationPath $intent.sources[$index] $Context.account
            $manifest = Get-WindowsTreeProof $path
            $observed = if ($manifest.entries[0].observation.kind -eq 'file') { $manifest.entries[0].observation } else { Get-WindowsManifestObservation $manifest }
            Assert-WindowsObservation $observed $intent.sourceObservations[$index]
            $plan = [DetoursOperationFiles]::PlanCopy($path)
            $name = [System.IO.Path]::GetFileName($path)
            if ([string]::IsNullOrEmpty($name) -or -not $names.Add($name)) { throw 'Archive source names collide.' }
            foreach ($member in $plan.inputs) {
                if ($member.observation.kind -eq 'directory' -and $member.observation.identity.volume -ceq $parent.identity.volume -and
                    $member.observation.identity.object -ceq $parent.identity.object) { throw 'Cannot create an archive inside its source.' }
                if ($member.observation.kind -eq 'file' -and $member.observation.byteCount -gt [uint32]::MaxValue) {
                    throw 'Built-in ZIP cannot archive entries larger than 4 GiB.'
                }
            }
            $sources += [pscustomobject]@{ location = $intent.sources[$index]; manifest = $manifest; plan = $plan; name = $name }
        }
        $Context.record | Add-Member -NotePropertyName windowsArchiveSources -NotePropertyValue $sources -Force
        Save-WindowsWorkspace $Context
        New-WindowsWorkspace $Context $destination | Out-Null
        $output = New-WindowsPayload $Context
        try {
            $archive = [System.IO.Compression.ZipArchive]::new($output, [System.IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($source in $sources) {
                    foreach ($member in $source.plan.inputs) {
                        Assert-WindowsOperationActive $Context
                        $relative = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($member.relativePath))
                        $name = if ($relative.Length -eq 0) { $source.name } else { $source.name + '/' + $relative }
                        if ($member.observation.kind -eq 'directory') { $archive.CreateEntry($name + '/') | Out-Null }
                        else { Add-WindowsAcceptedZipFile $Context $archive $name $member }
                    }
                }
            } finally { $archive.Dispose() }
            $output.Flush($true)
        } finally { $output.Dispose() }
        foreach ($source in $sources) {
            Assert-WindowsOperationActive $Context
            $path = Get-OperationPath $source.location $Context.account
            $after = Get-WindowsTreeProof $path
            Assert-WindowsTreeMovement $source.manifest $after
            for ($index = 0; $index -lt @($after.entries).Count; $index++) {
                Assert-WindowsObservation $after.entries[$index].observation $source.manifest.entries[$index].observation
            }
            Assert-WindowsCopyPlan $source.plan ([DetoursOperationFiles]::PlanCopy($path))
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
    function Add-WindowsAcceptedZipFile($Context, $Archive, [string]$Name, $Member) {
        $expected = $Member.observation
        $sourceStream = [DetoursOperationFiles]::OpenObservedFile($Member.sourcePath, $expected.identity.volume, $expected.identity.object, $expected.version)
        try {
            $entry = $Archive.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $output = $entry.Open()
            try {
                $buffer = [byte[]]::new(65536)
                while (($count = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    Assert-WindowsOperationActive $Context
                    $output.Write($buffer, 0, $count)
                }
            } finally { $output.Dispose() }
        } finally { $sourceStream.Dispose() }
    }
    """#
}
