import Foundation
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func exerciseSevenZipJunctionFixture(channel: PowerShellChannel, root: String) async throws {
        let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            \(WindowsOperationScripts.filesystemHelpers)
            \(WindowsArchiveScripts.externalToolHelpers)
            $env:PATH = (Join-Path $Arguments.root 'tools') + ';' + $env:PATH
            $target = Join-Path $Arguments.root 'junction-target'
            [System.IO.Directory]::CreateDirectory($target) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $target 'data.txt'), 'junction target bytes')
            $native = Join-Path $Arguments.root 'native-junction'
            $before = [DetoursOperationFiles]::CreateDirectoryExclusive($native)
            $after = [DetoursOperationFiles]::SetArchiveJunction($native, $before.identity.volume, $before.identity.object, $target)
            $selected = Join-Path $Arguments.root 'junction'
            New-Item -ItemType Junction -Path $selected -Target $target -ErrorAction Stop | Out-Null
            $tool = Resolve-ArchiveTool @('7z.exe', '7z')
            $archive = Join-Path $Arguments.root 'junction.7z'
            Invoke-ArchiveTool $tool @('a', '-t7z', '-snl', $archive, 'junction') $Arguments.root
            $legacy = Join-Path $Arguments.root 'legacy-junction'
            Invoke-ArchiveTool $tool @('x', '-y', ('-o' + $legacy), $archive) $null
            $legacyLink = [DetoursOperationFiles]::Observe((Join-Path $legacy 'junction'))
            @{ nativeIdentity = ($before.identity.object -ceq $after.identity.object).ToString()
               nativeKind = $after.kind; nativeBytes = [System.IO.File]::ReadAllText((Join-Path $native 'data.txt'))
               legacyKind = $legacyLink.kind
               legacyTarget = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($legacyLink.linkTarget))
               originalBytes = [System.IO.File]::ReadAllText((Join-Path $target 'data.txt')) }
            """), arguments: ["root": root])
        let result = try JSONDecoder().decode([String: String].self, from: await channel.run(script, operation: "SevenZipJunctionCompatibility"))
        XCTAssertEqual(result["nativeIdentity"], "True")
        XCTAssertEqual(result["nativeKind"], "symbolicLink")
        XCTAssertEqual(result["nativeBytes"], "junction target bytes")
        XCTAssertEqual(result["legacyKind"], "symbolicLink")
        XCTAssertEqual(result["originalBytes"], "junction target bytes")
        print("Archive compatibility: 7z junction target \(result["legacyTarget"] ?? "missing")")
    }
}
