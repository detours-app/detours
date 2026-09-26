import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class WindowsAcceptedOperationLiveTests: XCTestCase {
    struct Arguments: Encodable {
        let root: String
        let account: OperationAccount
        let operation: WindowsOperationArguments
        var trashFailure: String?
    }

    func testAcceptedWindowsUploadCommitRenameCancellationAndConflicts() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("a-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let rootData = try await channel.run(PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursAccepted-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            $root
            """)), operation: "AcceptedFixture")
        let root = try JSONDecoder().decode(String.self, from: rootData)
        do {
            try await exercise(channel: channel, root: root)
            try await exerciseReplacement(channel: channel, root: root)
            try await exerciseIngress(channel: channel, root: root, control: control)
            try await cleanup(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await cleanup(channel: channel, root: root) } catch { XCTFail("Accepted fixture cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    private func exercise(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest, trashFailure: String? = nil) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: trashFailure))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedFixtureRequest"))
        }
        guard case .handshake(let handshake) = try await send(.handshake) else { return XCTFail("No Windows operation handshake") }
        try handshake.validate(expectedAccount: account, expectedEpoch: nil)
        func identity(_ intent: OperationIntent) throws -> OperationRequestIdentity {
            .init(id: intent.id, account: account, epoch: handshake.epoch,
                  intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }
        let bytes = Data("verified incoming".utf8)
        let destination = location("destination")
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .editorUpload, sources: [],
            destination: destination, sourceObservations: [], conflict: .createNew, payloadProof: try OperationContentProof.data(bytes))
        let request = try identity(intent)
        guard case .accepted(let accepted) = try await send(.accept(identity: request, intent: intent)) else { return XCTFail("Upload was not accepted") }
        XCTAssertEqual(accepted.intent, intent)
        let ready = try await send(.prepareUpload(identity: request, contents: bytes))
        guard case .receipt(let preparation) = ready else { return XCTFail("No preparation receipt") }
        XCTAssertEqual(preparation.phase, .readyToCommit)
        let absent = try await send(.lookup(destination))
        XCTAssertEqual(absent, .lookup(.missing))
        let repeated = try await send(.prepareUpload(identity: request, contents: Data()))
        XCTAssertEqual(repeated, ready)
        let committed = try await send(.commit(request))
        guard case .receipt(let receipt) = committed else { return XCTFail("No commit receipt") }
        XCTAssertEqual(receipt.outcome, .committed, receipt.failure ?? "")
        XCTAssertTrue(receipt.recovery.isEmpty, receipt.failure ?? "")
        XCTAssertEqual(receipt.effects.first?.observation.sha256, intent.payloadProof?.sha256)
        let duplicateCommit = try await send(.commit(request))
        XCTAssertEqual(duplicateCommit, committed)

        let renamed = location("renamed")
        let renameIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .rename, sources: [destination],
            destination: renamed, sourceObservations: [try XCTUnwrap(receipt.effects.first?.observation)], conflict: .createNew)
        let renameRequest = try identity(renameIntent)
        _ = try await send(.accept(identity: renameRequest, intent: renameIntent))
        guard case .receipt(let rename) = try await send(.execute(renameRequest)) else { return XCTFail("No rename receipt") }
        XCTAssertEqual(rename.outcome, .committed, rename.failure ?? "")
        XCTAssertEqual(rename.sourceDisposition, .confirmed)
        let oldLocation = try await send(.lookup(destination))
        XCTAssertEqual(oldLocation, .lookup(.missing))

        let copyIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy, sources: [renamed],
            destination: location("copy"), sourceObservations: [try XCTUnwrap(rename.effects.first?.observation)], conflict: .createNew)
        let copyRequest = try identity(copyIntent)
        _ = try await send(.accept(identity: copyRequest, intent: copyIntent))
        guard case .receipt(let copyReady) = try await send(.prepareCopy(copyRequest)) else { return XCTFail("No copy preparation receipt") }
        XCTAssertEqual(copyReady.phase, .readyToCommit, copyReady.failure ?? "")
        guard case .receipt(let copy) = try await send(.commit(copyRequest)) else { return XCTFail("No copy result") }
        XCTAssertEqual(copy.outcome, .committed, copy.failure ?? "")
        XCTAssertTrue(copy.recovery.isEmpty)
        XCTAssertEqual(copy.effects.first?.observation.sha256, intent.payloadProof?.sha256)
        XCTAssertNotEqual(copy.effects.first?.observation.identity, rename.effects.first?.observation.identity)

        let folderIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .createFolder, sources: [],
            destination: location("folder"), sourceObservations: [], conflict: .createNew)
        let folderRequest = try identity(folderIntent)
        _ = try await send(.accept(identity: folderRequest, intent: folderIntent))
        guard case .receipt(let folder) = try await send(.execute(folderRequest)) else { return XCTFail("No folder result") }
        XCTAssertEqual(folder.outcome, .committed, folder.failure ?? "")
        XCTAssertEqual(folder.effects.first?.observation.kind, .directory)
        let duplicateFolder = try await send(.execute(folderRequest))
        XCTAssertEqual(duplicateFolder, .receipt(folder))

        let trashIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .trash, sources: [location("copy")],
            destination: nil, sourceObservations: [try XCTUnwrap(copy.effects.first?.observation)], conflict: .createNew)
        let trashRequest = try identity(trashIntent)
        _ = try await send(.accept(identity: trashRequest, intent: trashIntent))
        guard case .receipt(let trashed) = try await send(.execute(trashRequest)) else { return XCTFail("No Trash result") }
        XCTAssertEqual(trashed.outcome, .committed, trashed.failure ?? "")
        XCTAssertEqual(trashed.sourceDisposition, .confirmed)
        XCTAssertEqual(trashed.effects.first?.observation.sha256, intent.payloadProof?.sha256)
        let restoreReference = try XCTUnwrap(trashed.recovery.first(where: { $0.purpose == .sourceTrash }))
        XCTAssertEqual(restoreReference.original, location("copy"))
        XCTAssertEqual(restoreReference.knownLocation, trashed.effects.first?.location)
        let removedSource = try await send(.lookup(location("copy")))
        XCTAssertEqual(removedSource, .lookup(.missing))
        let duplicateTrash = try await send(.execute(trashRequest))
        XCTAssertEqual(duplicateTrash, .receipt(trashed))

        let restoreIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .restore,
            sources: [try XCTUnwrap(restoreReference.knownLocation)], destination: location("copy"),
            sourceObservations: [try XCTUnwrap(trashed.effects.first?.observation)], conflict: .createNew, reverses: trashIntent.id)
        let restoreRequest = try identity(restoreIntent)
        _ = try await send(.accept(identity: restoreRequest, intent: restoreIntent))
        guard case .receipt(let restoredCopy) = try await send(.execute(restoreRequest)) else { return XCTFail("No restore result") }
        XCTAssertEqual(restoredCopy.outcome, .committed, restoredCopy.failure ?? "")
        XCTAssertEqual(restoredCopy.effects.first?.observation.identity, copy.effects.first?.observation.identity)
        XCTAssertEqual(restoredCopy.effects.first?.observation.sha256, intent.payloadProof?.sha256)
        XCTAssertTrue(restoredCopy.recovery.isEmpty, restoredCopy.failure ?? "")
        let duplicateRestore = try await send(.execute(restoreRequest))
        XCTAssertEqual(duplicateRestore, .receipt(restoredCopy))
        guard case .status(let consumedTrash) = try await send(.status(trashRequest)) else { return XCTFail("No consumed Trash record") }
        XCTAssertTrue(try XCTUnwrap(consumedTrash.receipt).recovery.isEmpty)

        let unauthorizedIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .restore,
            sources: [location("copy")], destination: location("unapproved"),
            sourceObservations: [try XCTUnwrap(restoredCopy.effects.first?.observation)], conflict: .createNew, reverses: trashIntent.id)
        let unauthorizedRequest = try identity(unauthorizedIntent)
        _ = try await send(.accept(identity: unauthorizedRequest, intent: unauthorizedIntent))
        guard case .receipt(let unauthorized) = try await send(.execute(unauthorizedRequest)) else { return XCTFail("No refused restore result") }
        XCTAssertEqual(unauthorized.outcome, .failedUnchanged, unauthorized.failure ?? "")

        let cancelledIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .editorUpload, sources: [],
            destination: location("cancelled"), sourceObservations: [], conflict: .createNew, payloadProof: intent.payloadProof)
        let cancelledRequest = try identity(cancelledIntent)
        _ = try await send(.accept(identity: cancelledRequest, intent: cancelledIntent))
        _ = try await send(.cancel(cancelledRequest))
        guard case .receipt(let cancelled) = try await send(.prepareUpload(identity: cancelledRequest, contents: bytes)) else {
            return XCTFail("No cancellation receipt")
        }
        XCTAssertEqual(cancelled.outcome, .failedUnchanged)
        XCTAssertTrue(cancelled.effects.isEmpty)
        XCTAssertTrue(cancelled.recovery.isEmpty)

        let occupiedIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .editorUpload, sources: [],
            destination: renamed, sourceObservations: [], conflict: .createNew, payloadProof: intent.payloadProof)
        let occupiedRequest = try identity(occupiedIntent)
        _ = try await send(.accept(identity: occupiedRequest, intent: occupiedIntent))
        guard case .receipt(let refused) = try await send(.prepareUpload(identity: occupiedRequest, contents: bytes)) else {
            return XCTFail("No conflict receipt")
        }
        XCTAssertEqual(refused.outcome, .failedUnchanged)
        guard case .lookup(.found(let preserved)) = try await send(.lookup(renamed)) else { return XCTFail("Original was lost") }
        XCTAssertEqual(preserved.identity, rename.effects.first?.observation.identity)

        let wrongEpoch = OperationRequestIdentity(id: request.id, account: account, epoch: UUID(), intentDigest: request.intentDigest)
        let incompatible = try await send(.status(wrongEpoch))
        XCTAssertEqual(incompatible, .incompatible(.epochChanged))
        let status = try await send(.status(request))
        guard case .status(let snapshot) = status else { return XCTFail("No recorded result") }
        XCTAssertEqual(snapshot.receipt, receipt)
        XCTAssertNil(snapshot.workspace)

        let rollbackIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .trash, sources: [renamed],
            destination: nil, sourceObservations: [try XCTUnwrap(rename.effects.first?.observation)], conflict: .createNew)
        let rollbackRequest = try identity(rollbackIntent)
        _ = try await send(.accept(identity: rollbackRequest, intent: rollbackIntent))
        guard case .receipt(let rollback) = try await send(.execute(rollbackRequest), trashFailure: "changed") else {
            return XCTFail("No changed-source Trash result")
        }
        XCTAssertEqual(rollback.outcome, .failedUnchanged, rollback.failure ?? "")
        XCTAssertEqual(rollback.sourceDisposition, .present)
        XCTAssertTrue(rollback.recovery.isEmpty)
        guard case .lookup(.found(let restored)) = try await send(.lookup(renamed)) else { return XCTFail("Changed source was not restored") }
        XCTAssertEqual(restored.identity, rename.effects.first?.observation.identity)

        let blockedIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .trash, sources: [renamed],
            destination: nil, sourceObservations: [restored], conflict: .createNew)
        let blockedRequest = try identity(blockedIntent)
        _ = try await send(.accept(identity: blockedRequest, intent: blockedIntent))
        guard case .receipt(let blocked) = try await send(.execute(blockedRequest), trashFailure: "occupied") else {
            return XCTFail("No blocked Trash rollback result")
        }
        XCTAssertEqual(blocked.outcome, .partial, blocked.failure ?? "")
        let held = try XCTUnwrap(blocked.recovery.first(where: { $0.purpose == .sourceTrash })?.knownLocation)
        guard case .windows(let heldPath) = held.path else { return XCTFail("No Windows holding path") }
        let contentsScript = try PowerShellScript(source: """
            param($Arguments)
            @{ source = [System.IO.File]::ReadAllText($Arguments.source); held = [System.IO.File]::ReadAllText($Arguments.held) }
            """, arguments: ["source": root + "\\renamed", "held": heldPath])
        let contents = try JSONDecoder().decode([String: String].self,
            from: await channel.run(contentsScript, operation: "CheckTrashRollbackContents"))
        XCTAssertEqual(contents["source"], "competing writer")
        XCTAssertEqual(contents["held"], "changed after move")

        guard case .lookup(.found(let retained)) = try await send(.lookup(held)) else { return XCTFail("Held source missing") }
        let occupiedRestoreIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .restore,
            sources: [held], destination: renamed, sourceObservations: [retained], conflict: .createNew, reverses: blockedIntent.id)
        let occupiedRestoreRequest = try identity(occupiedRestoreIntent)
        _ = try await send(.accept(identity: occupiedRestoreRequest, intent: occupiedRestoreIntent))
        guard case .receipt(let occupiedRestore) = try await send(.execute(occupiedRestoreRequest)) else {
            return XCTFail("No occupied restore result")
        }
        XCTAssertEqual(occupiedRestore.outcome, .failedUnchanged, occupiedRestore.failure ?? "")
        let preservedContents = try JSONDecoder().decode([String: String].self,
            from: await channel.run(contentsScript, operation: "CheckRefusedRestoreContents"))
        XCTAssertEqual(preservedContents, contents)
    }

    private func exerciseIngress(channel: PowerShellChannel, root: String, control: URL) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func send(_ arguments: WindowsOperationArguments) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: arguments))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedIngressRequest"))
        }
        guard case .handshake(let handshake) = try await send(WindowsOperationArguments(.handshake)) else {
            return XCTFail("No ingress handshake")
        }
        let bytes = Data(repeating: 73, count: 1_048_577)
        let local = control.appendingPathComponent("ingress-upload")
        try bytes.write(to: local)
        let destination = OperationLocation(account: account, path: .windows(root + "\\sealed"))
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .editorUpload, sources: [],
            destination: destination, sourceObservations: [], conflict: .createNew, payloadProof: try OperationContentProof.data(bytes))
        let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
            intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        _ = try await send(WindowsOperationArguments(.accept(identity: identity, intent: intent)))
        let allocated = try await send(.init(ingress: .prepareIngress(identity)))
        guard case .receipt(let allocation) = allocated,
              case .windows(let ingress) = allocation.preparedPayload?.location.path else { return XCTFail("No ingress allocation") }
        XCTAssertEqual(allocation.phase, .preparing, allocation.failure ?? "")
        let duplicate = try await send(.init(ingress: .prepareIngress(identity)))
        XCTAssertEqual(duplicate, allocated)
        let sftp = ProcessWindowsSFTPClient(sshTarget: "detours-windows", controlDirectory: control, hostTrust: SSHHostTrust())
        try await sftp.upload(localURL: local, remotePath: ingress)

        let transport = PowerShellProcessTransport(sshTarget: "detours-windows", controlDirectory: control,
            hostTrust: SSHHostTrust(), executionMode: .persistent)
        let writer = PowerShellChannel(transport: transport)
        do {
            _ = try await writer.run(PowerShellScript(source: """
                param($Arguments)
                $global:IngressWriter = [System.IO.FileStream]::new($Arguments.path, 'Open', 'ReadWrite', 'ReadWrite,Delete')
                $true
                """, arguments: ["path": ingress]), operation: "HoldIngressWriter")
            guard case .receipt(let sealed) = try await send(.init(ingress: .sealIngress(identity))) else {
                throw PowerShellChannelError.invalidResponse("No sealed receipt")
            }
            XCTAssertEqual(sealed.phase, .readyToCommit, sealed.failure ?? "")
            XCTAssertNotEqual(sealed.preparedPayload?.observation.identity, allocation.preparedPayload?.observation.identity)
            guard case .receipt(let committed) = try await send(WindowsOperationArguments(.commit(identity))) else {
                throw PowerShellChannelError.invalidResponse("No sealed commit")
            }
            XCTAssertEqual(committed.outcome, .committed, committed.failure ?? "")
            XCTAssertFalse(committed.recovery.isEmpty, "An open ingress writer must leave a cleanup obligation")
            _ = try await writer.run(PowerShellScript(source: """
                $global:IngressWriter.Position = 0
                $global:IngressWriter.WriteByte(88)
                $global:IngressWriter.Flush($true)
                $true
                """), operation: "LateIngressWrite")
            let verification = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
                param($Arguments)
                \(WindowsOperationScripts.filesystemHelpers)
                [DetoursOperationFiles]::Prove($Arguments.path)
                """), arguments: ["path": root + "\\sealed"])
            let observed = try JSONDecoder().decode(OperationObservation.self,
                from: await channel.run(verification, operation: "VerifySealedFile"))
            XCTAssertEqual(observed.sha256, intent.payloadProof?.sha256)
            XCTAssertEqual(observed.identity, committed.effects.first?.observation.identity)
            _ = try await writer.run(PowerShellScript(source: "$global:IngressWriter.Dispose(); $true"), operation: "CloseIngressWriter")
            await transport.stop()
        } catch {
            await transport.stop()
            throw error
        }
    }

    func cleanup(channel: PowerShellChannel, root: String) async throws {
        struct Cleanup: Encodable { let root: String }
        let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            function Remove-FixtureDirectory([string]$Path) {
                foreach ($child in [System.IO.Directory]::GetFileSystemEntries($Path)) {
                    $attributes = [System.IO.File]::GetAttributes($child)
                    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                            [System.IO.Directory]::Delete($child)
                        } else { Remove-FixtureDirectory $child }
                    } else { [System.IO.File]::Delete($child) }
                }
                [System.IO.Directory]::Delete($Path)
            }
            Remove-FixtureDirectory ([string]$Arguments.root)
            """), arguments: Cleanup(root: root))
        _ = try await channel.run(script, operation: "AcceptedFixtureCleanup")
    }

    static let requestScript = #"""
    param($Arguments)
    \#(WindowsOperationScripts.filesystemHelpers)
    \#(WindowsOperationScripts.journalHelpers)
    \#(WindowsOperationScripts.requestHelpers)
    \#(WindowsOperationScripts.mutationHelpers)
    \#(WindowsOperationScripts.ingressHelpers)
    \#(WindowsOperationScripts.trashHelpers)
    \#(WindowsOperationScripts.restoreHelpers)
    \#(WindowsOperationScripts.replacementHelpers)
    \#(WindowsOperationScripts.backupHandoffHelpers)
    \#(WindowsOperationScripts.treeProofHelpers)
    \#(WindowsOperationScripts.treeCopyHelpers)
    \#(WindowsOperationScripts.archiveHelpers)
    \#(WindowsOperationScripts.zipPlanHelpers)
    \#(WindowsOperationScripts.zipExtractionHelpers)
    \#(WindowsOperationScripts.deletionHelpers)
    \#(WindowsArchiveScripts.externalToolHelpers)
    \#(WindowsOperationScripts.archiveProcessHelpers)
    \#(WindowsOperationScripts.tarCreationHelpers)
    \#(WindowsOperationScripts.tarReaderHelpers)
    \#(WindowsOperationScripts.tarExtractionHelpers)
    \#(WindowsOperationScripts.tarLinkHelpers)
    $nativeConfirmedDelete = ${function:Remove-WindowsConfirmedEntry}
    function Remove-WindowsConfirmedEntry($Context, [string]$Path, $Expected) {
        if ($Arguments.trashFailure -eq 'deleteLaterChild' -and $Path.EndsWith('a.txt')) { throw 'Injected later-child deletion refusal.' }
        & $nativeConfirmedDelete $Context $Path $Expected
    }
    $nativeZipFile = ${function:Add-WindowsAcceptedZipFile}
    function Add-WindowsAcceptedZipFile($Context, $Archive, [string]$Name, $Member) {
        & $nativeZipFile $Context $Archive $Name $Member
        if ($Arguments.trashFailure -eq 'zipSourceChanged' -and $Name.EndsWith('/data.txt')) {
            [System.IO.File]::WriteAllText($Member.sourcePath, 'modified source')
        }
    }
    $nativeTreeCopy = ${function:Copy-WindowsTreeFile}
    function Copy-WindowsTreeFile($Context, [string]$Source, [string]$Target, [string]$Name, $Expected) {
        if ($Arguments.trashFailure -eq 'treeCopyFailed' -and $Name.EndsWith('/z.txt')) { throw 'Injected later child read failure.' }
        & $nativeTreeCopy $Context $Source $Target $Name $Expected
    }
    $nativeTreeProof = ${function:Get-WindowsTreeProof}
    function Get-WindowsTreeProof([string]$Path) {
        $probe = [System.IO.FileStream]::new((Join-Path (Join-Path $Arguments.root 'journal') 'commit.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $probe.Dispose()
        if ($Arguments.trashFailure -eq 'treeChanged' -and $Path.Contains('\.detours-trash\')) {
            [System.IO.File]::WriteAllText((Join-Path $Path 'child.txt'), 'modified')
        }
        if ($Arguments.trashFailure -eq 'treeReplyLost' -and $Path.EndsWith('\renamed-folder') -and -not $script:TreeReplyLost) {
            $script:TreeReplyLost = $true
            throw 'Injected interruption after native tree publication.'
        }
        if ($Arguments.trashFailure -eq 'treeResultChanged' -and $Path.EndsWith('\unconfirmed-folder') -and -not $script:TreeResultChanged) {
            $script:TreeResultChanged = $true
            [System.IO.File]::WriteAllText((Join-Path $Path 'child.txt'), 'later writer')
            throw 'Injected changed tree after native publication.'
        }
        & $nativeTreeProof $Path
    }
    $nativeBackupReference = ${function:Set-WindowsBackupReference}
    function Set-WindowsBackupReference($Context, $KnownLocation, $Locations) {
        & $nativeBackupReference $Context $KnownLocation $Locations
        if ($Arguments.trashFailure -eq 'handoffRefused' -and $Context.record.receipt.outcome -eq 'committed' -and $null -eq $KnownLocation) {
            throw 'Injected refusal after reserving the backup Trash location.'
        }
    }
    $nativeProof = ${function:Get-WindowsContentProof}
    function Get-WindowsContentProof([string]$Path) {
        $probe = [System.IO.FileStream]::new((Join-Path (Join-Path $Arguments.root 'journal') 'commit.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $probe.Dispose()
        if ($Path.EndsWith('\displaced')) {
            if ($Arguments.trashFailure -eq 'replacementChanged') { [System.IO.File]::WriteAllText($Path, 'changed original') }
            elseif ($Arguments.trashFailure -eq 'replacementOccupied') {
                [System.IO.File]::WriteAllText((Join-Path $Arguments.root 'copy'), 'competing replacement writer')
                throw 'Injected displaced-original verification failure.'
            }
        }
        if ($Path.Contains('\.detours-trash\') -and $Arguments.trashFailure) {
            if ($Arguments.trashFailure -eq 'changed') { [System.IO.File]::WriteAllText($Path, 'changed after move') }
            elseif ($Arguments.trashFailure -eq 'occupied') {
                [System.IO.File]::WriteAllText((Join-Path $Arguments.root 'renamed'), 'competing writer')
                throw 'Injected post-move verification failure.'
            }
        }
        & $nativeProof $Path
    }
    Invoke-WindowsOperation (Join-Path $Arguments.root 'journal') $Arguments.account $Arguments.operation.request $Arguments.operation.canonicalIntent
    """#
}
