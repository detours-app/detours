import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RarWindowsFixture {
    let channel: PowerShellChannel
    let root: String
    let control: URL
    let account = OperationAccount(hostIdentity: "rar-fixture", accountIdentity: "rar-fixture-user")

    private init(channel: PowerShellChannel, root: String, control: URL) {
        self.channel = channel
        self.root = root
        self.control = control
    }

    static func create() async throws -> RarWindowsFixture {
        let control = URL(fileURLWithPath: "/tmp/rw-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursRar-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            $root
            """))
        do {
            let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "RarFixture"))
            let fixture = RarWindowsFixture(channel: channel, root: root, control: control)
            do {
                let tools = try XCTUnwrap(ProcessInfo.processInfo.environment["DETOURS_7ZIP_FIXTURE"])
                for name in ["7z.exe", "7z.dll"] {
                    try await fixture.write("tools/" + name, bytes: Data(contentsOf: URL(fileURLWithPath: tools).appendingPathComponent(name)))
                }
                return fixture
            } catch {
                try await fixture.cleanup()
                throw error
            }
        } catch {
            await channel.disconnect()
            if FileManager.default.fileExists(atPath: control.path) { try FileManager.default.removeItem(at: control) }
            throw error
        }
    }

    func location(_ relative: String) -> OperationLocation {
        .init(account: account, path: .windows(root + "\\" + relative.replacingOccurrences(of: "/", with: "\\")))
    }

    func send(_ request: OperationRequest) async throws -> OperationReply {
        let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody:
            WindowsAcceptedOperationLiveTests.sevenZipFixtureScript(WindowsAcceptedOperationLiveTests.requestScript)),
            arguments: WindowsAcceptedOperationLiveTests.Arguments(root: root, account: account,
                operation: WindowsOperationArguments(request), trashFailure: nil))
        return try OperationReply.decode(await channel.run(script, operation: "RarAcceptedOperation"))
    }

    func write(_ relative: String, bytes: Data) async throws {
        let script = try PowerShellScript(source: """
            param($Arguments)
            $path = Join-Path $Arguments.root $Arguments.relative
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path)) | Out-Null
            [System.IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($Arguments.bytes))
            $true
            """, arguments: ["root": root, "relative": relative, "bytes": bytes.base64EncodedString()])
        _ = try await channel.run(script, operation: "RarFixtureBytes")
    }

    func stage(_ archive: RarTestCorpus.Archive, folder: String) async throws -> [String] {
        var names: [String] = []
        for part in archive.parts {
            let name = folder + "/" + URL(fileURLWithPath: part).lastPathComponent
            try await write(name, bytes: Data(contentsOf: RarTestCorpus.source(part)))
            names.append(name)
        }
        return names
    }

    func layout(_ selected: String, password: String?) async throws -> OperationArchiveLayout {
        let reply = try await send(.archiveLayout(location: location(selected), format: "rar", password: password))
        guard case .archiveLayout(.found(let layout)) = reply else {
            XCTFail("RAR layout failed: \(reply)")
            throw OperationContractError.invalidReceipt
        }
        return layout
    }

    func accept(_ layout: OperationArchiveLayout, destination: String, encrypted: Bool) async throws -> OperationRequestIdentity {
        guard case .handshake(let handshake) = try await send(.handshake) else { throw OperationContractError.invalidReceipt }
        XCTAssertTrue(handshake.capabilities.contains(.rarExtraction))
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveExtract,
            sources: try XCTUnwrap(layout.rarSources), destination: location(destination),
            sourceObservations: try XCTUnwrap(layout.rarObservations), conflict: .createNew, archiveFormat: "rar", archiveEncrypted: encrypted)
        let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
            intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        _ = try await send(.accept(identity: identity, intent: intent))
        return identity
    }

    func receipt(_ request: OperationRequest) async throws -> OperationReceipt {
        let reply = try await send(request)
        guard case .receipt(let receipt) = reply else {
            XCTFail("Missing RAR receipt: \(reply)")
            throw OperationContractError.invalidReceipt
        }
        return receipt
    }

    func verify(_ archive: RarTestCorpus.Archive, destination: String) async throws {
        struct Arguments: Encodable { let root: String; let destination: String; let names: [String] }
        struct Entry: Decodable { let directory: Bool; let bytes: String? }
        let names = archive.expected.map { expected in
            archive.rootName == nil ? expected.name : expected.name.split(separator: "/").dropFirst().joined(separator: "/")
        }
        let script = try PowerShellScript(source: """
            param($Arguments)
            $base = Join-Path $Arguments.root $Arguments.destination
            $result = @{}
            foreach ($name in $Arguments.names) {
                $path = if ([string]::IsNullOrEmpty($name)) { $base } else { Join-Path $base $name }
                $directory = [System.IO.Directory]::Exists($path)
                $bytes = if ($directory) { $null } else { [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path)) }
                $result[$name] = @{ directory = $directory; bytes = $bytes }
            }
            $result
            """, arguments: Arguments(root: root, destination: destination, names: names))
        let result = try JSONDecoder().decode([String: Entry].self, from: await channel.run(script, operation: "RarIndependentContents"))
        for (name, expected) in zip(names, archive.expected) {
            let entry = try XCTUnwrap(result[name])
            XCTAssertEqual(entry.directory, expected.kind == "directory", expected.name)
            if !entry.directory { try expected.assertBytes(XCTUnwrap(Data(base64Encoded: try XCTUnwrap(entry.bytes)))) }
        }
    }

    func assertMissing(_ relative: String) async throws {
        let reply = try await send(.lookup(location(relative)))
        guard case .lookup(.missing) = reply else { return XCTFail("Unexpected RAR output: \(reply)") }
    }

    func probe(_ body: String, values: [String: String] = [:]) async throws -> [String: String] {
        var arguments = values
        arguments["root"] = root
        let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            \(WindowsOperationScripts.filesystemHelpers)
            \(body)
            """), arguments: arguments)
        return try JSONDecoder().decode([String: String].self, from: await channel.run(script, operation: "RarFixtureVerification"))
    }

    func assertPrivate(_ secret: String) async throws {
        let result = try await probe("""
            $found = $false
            foreach ($file in [System.IO.Directory]::GetFiles((Join-Path $Arguments.root 'journal'), '*', 'AllDirectories')) {
                if ([System.IO.File]::ReadAllText($file).Contains($Arguments.secret)) { $found = $true }
            }
            @{ leaked = $found.ToString(); scratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-partial-*', 'AllDirectories')).Count.ToString() }
            """, values: ["secret": secret])
        XCTAssertEqual(result["leaked"], "False")
        XCTAssertEqual(result["scratch"], "0")
    }

    func cleanup() async throws {
        do {
            try await WindowsAcceptedOperationLiveTests.cleanupFixture(channel: channel, root: root)
            await channel.disconnect()
            try FileManager.default.removeItem(at: control)
        } catch {
            await channel.disconnect()
            throw error
        }
    }
}
