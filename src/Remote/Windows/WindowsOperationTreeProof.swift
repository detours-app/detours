import Foundation

extension WindowsOperationScripts {
    static let treeProofHelpers = #"""
    function Get-WindowsTreeProof([string]$Path) {
        [DetoursOperationFiles]::Manifest($Path)
    }
    function Get-WindowsManifestObservation($Manifest) {
        $root = $Manifest.entries[0].observation
        [pscustomobject]@{
            identity = $root.identity; kind = $root.kind; version = $root.version; byteCount = $root.byteCount
            sha256 = $Manifest.proof.sha256; linkTarget = $root.linkTarget; contentVersion = $root.contentVersion
        }
    }
    function Assert-WindowsTreeMovement($Before, $After) {
        if ($Before.proof.sha256 -cne $After.proof.sha256 -or $Before.proof.byteCount -ne $After.proof.byteCount -or
            @($Before.entries).Count -ne @($After.entries).Count) { throw 'Moved source tree content changed.' }
        for ($index = 0; $index -lt @($Before.entries).Count; $index++) {
            $expected = $Before.entries[$index]; $actual = $After.entries[$index]
            if ($actual.relativePath -cne $expected.relativePath -or
                $actual.observation.identity.volume -cne $expected.observation.identity.volume -or
                $actual.observation.identity.object -cne $expected.observation.identity.object -or
                $actual.observation.contentVersion -cne $expected.observation.contentVersion) { throw 'Moved source tree object changed.' }
        }
    }
    """#
}
