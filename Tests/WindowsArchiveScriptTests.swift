import XCTest
@testable import Detours

final class WindowsArchiveScriptTests: XCTestCase {
    func testRarCapabilitiesDoNotChangeOtherFormats() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("rar-win-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursRarCapabilities-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "RarCapabilitiesFixture"))
        do {
            let probe = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
                param($Arguments)
                \(WindowsOperationScripts.sevenZipRuntimeHelpers)
                \(WindowsOperationScripts.sevenZipExtractionHelpers)
                \(WindowsOperationScripts.archiveLayoutHelpers)
                $tools = Join-Path $Arguments.root 'tools'
                [System.IO.Directory]::CreateDirectory($tools) | Out-Null
                $script:tool = Join-Path $tools '7z.exe'
                function Resolve-ArchiveTool($Names) { $script:tool }
                $results = @{}
                $source = Join-Path $Arguments.root 'sample.rar'
                try { $library = Open-WindowsRarLibrary $source; $library.Dispose(); throw 'Missing DLL accepted.' }
                catch { $results.missing = $_.Exception.GetBaseException().Message }
                [System.IO.File]::WriteAllText((Join-Path $tools '7z.dll'), 'invalid DLL fixture')
                try { $library = Open-WindowsRarLibrary $source; $library.Dispose(); throw 'Invalid DLL accepted.' }
                catch { $results.incompatible = $_.Exception.GetBaseException().Message }
                try { $library = Open-WindowsRarLibrary (Join-Path $tools 'sample.rar'); $library.Dispose(); throw 'Archive-directory DLL accepted.' }
                catch { $results.archiveDirectory = $_.Exception.GetBaseException().Message }
                foreach ($format in @('zip', 'sevenZ')) {
                    try { Get-WindowsArchiveLayout $source $format 'private-test-password' $Arguments.root @{ kind = 'file' } $null | Out-Null
                        throw 'Non-RAR password accepted.' }
                    catch { $results[$format] = $_.Exception.GetBaseException().Message }
                }
                $intent = @{ archiveFormat = 'sevenZ'; sources = @('source'); sourceObservations = @('proof'); archiveEncrypted = $true }
                try { Prepare-WindowsSevenZipExtraction @{ record = @{ intent = $intent } } @{ password = 'private-test-password' } | Out-Null
                    throw 'Encrypted 7Z preparation accepted.' }
                catch { $results.preparation = $_.Exception.GetBaseException().Message }
                $results
                """), arguments: ["root": root])
            let results = try JSONDecoder().decode([String: String].self, from: await channel.run(probe, operation: "RarCapabilities"))
            for key in ["missing", "incompatible", "archiveDirectory"] {
                XCTAssertEqual(results[key], "RAR requires a compatible free 7-Zip installation. Download it from https://www.7-zip.org/download.html")
            }
            for key in ["zip", "sevenZ", "preparation"] {
                XCTAssertEqual(results[key], "Password-protected archives are not supported on Windows remote machines.")
            }
            XCTAssertFalse(results.values.joined().contains("private-test-password"))
            try await WindowsAcceptedOperationLiveTests.cleanupFixture(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await WindowsAcceptedOperationLiveTests.cleanupFixture(channel: channel, root: root) } catch {
                XCTFail("RAR capability fixture cleanup failed: \(error)")
            }
            await channel.disconnect()
            throw error
        }
    }

    func testZipArchiveIncludesHiddenEntries() {
        let script = WindowsArchiveScripts.zipCreate

        XCTAssertTrue(script.hasPrefix("param($Arguments)"))
        XCTAssertTrue(script.contains("System.IO.Compression.ZipArchive"))
        XCTAssertTrue(script.contains("Get-ChildItem -LiteralPath $Item.FullName -Force"))
        XCTAssertTrue(script.contains("Get-RelativeArchiveName"))
        XCTAssertTrue(script.contains("Built-in ZIP cannot archive entries larger than 4 GiB"))
        XCTAssertFalse(script.contains("Compress-Archive"))
    }

    func testArchiveExtractRejectsEscapingEntries() {
        for script in [WindowsArchiveScripts.zipExtract, WindowsArchiveScripts.externalExtract] {
            XCTAssertTrue(script.contains("Assert-PathWithinDirectory"))
            XCTAssertTrue(script.contains("escapes the destination directory"))
        }
        // The built-in zip path validates each entry's destination before extracting it.
        XCTAssertTrue(WindowsArchiveScripts.zipExtract.contains("foreach ($entry in $zip.Entries)"))
    }
}
