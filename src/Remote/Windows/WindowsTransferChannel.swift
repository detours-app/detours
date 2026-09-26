import Foundation
import RemoteOperationSupport

enum WindowsTransferError: Error, Equatable, LocalizedError {
    case unsupportedLargeTransferWithoutSFTP(byteCount: Int64)
    case byteCountMismatch(expected: Int64, actual: Int64)
    case invalidBase64Payload
    case partialFileMissing
    case invalidAcceptedUpload
    case acceptedOperationRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedLargeTransferWithoutSFTP(let byteCount):
            return "SFTP is unavailable on this Windows host, and the \(byteCount)-byte transfer is too large for the PowerShell fallback."
        case .byteCountMismatch(let expected, let actual):
            return "Windows transfer byte count mismatch: expected \(expected), got \(actual)."
        case .invalidBase64Payload:
            return "Windows transfer returned invalid base64 data."
        case .partialFileMissing:
            return "The downloaded partial file was missing before it could be finalized."
        case .acceptedOperationRequired:
            return "Remote changes require an accepted operation. Reconnect with a compatible Detours client."
        case .invalidAcceptedUpload:
            return "The Windows host returned an invalid upload preparation result."
        }
    }
}

protocol WindowsSFTPClient: Sendable {
    func download(remotePath: String, to localURL: URL) async throws
    func upload(localURL: URL, remotePath: String) async throws
}

actor WindowsTransferChannel {
    private let powerShellChannel: PowerShellChannel
    private let sftpClient: any WindowsSFTPClient
    private let fallbackThreshold: Int64

    init(
        sshTarget: String,
        powerShellChannel: PowerShellChannel,
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust(),
        fallbackThreshold: Int64 = RemoteTransferChannel.rpcThresholdBytes
    ) {
        self.powerShellChannel = powerShellChannel
        self.sftpClient = ProcessWindowsSFTPClient(
            sshTarget: sshTarget,
            controlDirectory: controlDirectory,
            hostTrust: hostTrust
        )
        self.fallbackThreshold = fallbackThreshold
    }

    init(
        powerShellChannel: PowerShellChannel,
        sftpClient: any WindowsSFTPClient,
        fallbackThreshold: Int64 = RemoteTransferChannel.rpcThresholdBytes
    ) {
        self.powerShellChannel = powerShellChannel
        self.sftpClient = sftpClient
        self.fallbackThreshold = fallbackThreshold
    }

    func download(remotePath: String, expectedByteCount: Int64, to localURL: URL) async throws {
        let lifetime = try await powerShellChannel.acquireLifetime(.reader)
        defer { lifetime?.release() }
        let generation = try await powerShellChannel.readyForAuxiliaryRequest()
        do {
            try await downloadViaSFTP(remotePath: remotePath, expectedByteCount: expectedByteCount, to: localURL)
        } catch {
            try await powerShellChannel.validateAuxiliaryRequest(generation: generation)
            guard expectedByteCount <= fallbackThreshold else {
                throw WindowsTransferError.unsupportedLargeTransferWithoutSFTP(byteCount: expectedByteCount)
            }
            try await downloadViaPowerShell(remotePath: remotePath, expectedByteCount: expectedByteCount, to: localURL)
        }
        try await powerShellChannel.validateAuxiliaryRequest(generation: generation)
    }

    private func downloadViaSFTP(remotePath: String, expectedByteCount: Int64, to localURL: URL) async throws {
        // Stream into a .detours-partial temp, verify, then atomically swap into place, so an
        // interrupted or size-mismatched download never leaves a truncated file at the
        // destination.
        let partial = RemoteTransferChannel.partialURL(for: localURL)
        try preparePartial(partial, finalURL: localURL)
        do {
            try await sftpClient.download(remotePath: remotePath, to: partial)
            try verifyByteCount(partial, expected: expectedByteCount)
            try finalizePartial(partial, to: localURL)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    func upload(localURL: URL, remotePath: String, byteCount: Int64) async throws {
        throw WindowsTransferError.acceptedOperationRequired
    }

    func prepareAcceptedUpload(localURL: URL, identity: OperationRequestIdentity, sftpAvailable: Bool) async throws -> OperationReceipt {
        let lifetime = try await powerShellChannel.acquireLifetime(.reader)
        defer { lifetime?.release() }
        let generation = try await powerShellChannel.readyForAuxiliaryRequest()
        if !sftpAvailable {
            let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else { throw WindowsTransferError.invalidAcceptedUpload }
            guard size <= fallbackThreshold else {
                throw WindowsTransferError.unsupportedLargeTransferWithoutSFTP(byteCount: Int64(size))
            }
            let contents = try Data(contentsOf: localURL)
            guard contents.count <= fallbackThreshold else {
                throw WindowsTransferError.unsupportedLargeTransferWithoutSFTP(byteCount: Int64(contents.count))
            }
            return try await acceptedReceipt(WindowsOperationArguments(.prepareUpload(identity: identity, contents: contents)), identity: identity)
        }
        let allocation = try await acceptedReceipt(.init(ingress: .prepareIngress(identity)), identity: identity)
        if allocation.phase == .terminal || allocation.phase == .readyToCommit { return allocation }
        guard allocation.phase == .preparing, let payload = allocation.preparedPayload,
              payload.location.account == identity.account, case .windows(let ingress) = payload.location.path else {
            throw WindowsTransferError.invalidAcceptedUpload
        }
        try await sftpClient.upload(localURL: localURL, remotePath: ingress)
        try await powerShellChannel.validateAuxiliaryRequest(generation: generation)
        return try await acceptedReceipt(.init(ingress: .sealIngress(identity)), identity: identity)
    }

    private func acceptedReceipt(_ arguments: WindowsOperationArguments, identity: OperationRequestIdentity) async throws -> OperationReceipt {
        let script = try PowerShellScript(source: WindowsOperationScripts.protocolScript, arguments: arguments)
        let reply = try OperationReply.decode(await powerShellChannel.run(script, operation: "AcceptedUpload"))
        guard case .receipt(let receipt) = reply, receipt.id == identity.id, receipt.account == identity.account,
              receipt.epoch == identity.epoch, receipt.intentDigest == identity.intentDigest else {
            throw WindowsTransferError.invalidAcceptedUpload
        }
        return receipt
    }

    private func downloadViaPowerShell(remotePath: String, expectedByteCount: Int64, to localURL: URL) async throws {
        let script = try PowerShellScript(source: Self.downloadScript, arguments: PathArguments(path: remotePath))
        let data = try await powerShellChannel.run(script, operation: "DownloadFallback")
        let encoded = try JSONDecoder.detoursWindows.decode(String.self, from: data)
        guard let payload = Data(base64Encoded: encoded) else {
            throw WindowsTransferError.invalidBase64Payload
        }
        guard Int64(payload.count) == expectedByteCount else {
            throw WindowsTransferError.byteCountMismatch(expected: expectedByteCount, actual: Int64(payload.count))
        }

        let partial = RemoteTransferChannel.partialURL(for: localURL)
        try preparePartial(partial, finalURL: localURL)
        do {
            try payload.write(to: partial, options: .atomic)
            try finalizePartial(partial, to: localURL)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private func preparePartial(_ partial: URL, finalURL: URL) throws {
        try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
    }

    /// Move a verified partial into place. The guard is on the partial temp, not the final
    /// destination, so a stale file from an earlier interrupted attempt never blocks a retry:
    /// an interruption leaves no file at the destination, so the rename succeeds next time.
    private func finalizePartial(_ partial: URL, to localURL: URL) throws {
        guard FileManager.default.fileExists(atPath: partial.path) else {
            throw WindowsTransferError.partialFileMissing
        }
        try FileManager.default.moveItem(at: partial, to: localURL)
    }

    private func verifyByteCount(_ localURL: URL, expected: Int64) throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let actual = Int64(values.fileSize ?? 0)
        guard actual == expected else {
            throw WindowsTransferError.byteCountMismatch(expected: expected, actual: actual)
        }
    }
}

final class ProcessWindowsSFTPClient: WindowsSFTPClient, @unchecked Sendable {
    private let sshTarget: String
    private let controlDirectory: URL
    private let hostTrust: SSHHostTrust
    private let processFactory: @Sendable () -> Process

    init(
        sshTarget: String,
        controlDirectory: URL,
        hostTrust: SSHHostTrust,
        processFactory: @escaping @Sendable () -> Process = { Process() }
    ) {
        self.sshTarget = sshTarget
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.processFactory = processFactory
    }

    func download(remotePath: String, to localURL: URL) async throws {
        try await runBatch(commands: [
            "get \(Self.quote(Self.sftpPath(fromNativePath: remotePath))) \(Self.quote(localURL.path))",
        ])
    }

    func upload(localURL: URL, remotePath: String) async throws {
        try await runBatch(commands: [
            "put \(Self.quote(localURL.path)) \(Self.quote(Self.sftpPath(fromNativePath: remotePath)))",
        ])
    }

    private func runBatch(commands: [String]) async throws {
        try hostTrust.prepareKnownHostsFile()
        let process = processFactory()
        let stdin = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = [
            "-b", "-",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
        ] + hostTrust.sshArguments + [sshTarget]
        process.standardInput = stdin
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data((commands.joined(separator: "\n") + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw RemoteTransferError.processFailed(message)
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func sftpPath(fromNativePath nativePath: String) -> String {
        let normalized = nativePath.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2 else { return normalized }
        let driveSeparator = normalized.index(after: normalized.startIndex)
        guard normalized[driveSeparator] == ":" else { return normalized }
        return "/" + normalized
    }
}

private extension WindowsTransferChannel {
    static let downloadScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Arguments.path))
        """
    )

}
