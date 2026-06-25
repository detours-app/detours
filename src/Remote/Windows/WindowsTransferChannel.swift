import Foundation

enum WindowsTransferError: Error, Equatable, LocalizedError {
    case unsupportedLargeTransferWithoutSFTP(byteCount: Int64)
    case byteCountMismatch(expected: Int64, actual: Int64)
    case invalidBase64Payload

    var errorDescription: String? {
        switch self {
        case .unsupportedLargeTransferWithoutSFTP(let byteCount):
            return "SFTP is unavailable on this Windows host, and the \(byteCount)-byte transfer is too large for the PowerShell fallback."
        case .byteCountMismatch(let expected, let actual):
            return "Windows transfer byte count mismatch: expected \(expected), got \(actual)."
        case .invalidBase64Payload:
            return "Windows transfer returned invalid base64 data."
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
        do {
            try await sftpClient.download(remotePath: remotePath, to: localURL)
            try verifyByteCount(localURL, expected: expectedByteCount)
        } catch {
            guard expectedByteCount <= fallbackThreshold else {
                throw WindowsTransferError.unsupportedLargeTransferWithoutSFTP(byteCount: expectedByteCount)
            }
            try await downloadViaPowerShell(remotePath: remotePath, expectedByteCount: expectedByteCount, to: localURL)
        }
    }

    func upload(localURL: URL, remotePath: String, byteCount: Int64) async throws {
        do {
            try await sftpClient.upload(localURL: localURL, remotePath: remotePath)
        } catch {
            guard byteCount <= fallbackThreshold else {
                throw WindowsTransferError.unsupportedLargeTransferWithoutSFTP(byteCount: byteCount)
            }
            try await uploadViaPowerShell(localURL: localURL, remotePath: remotePath, byteCount: byteCount)
        }
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
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        do {
            try payload.write(to: partial, options: .atomic)
            guard !FileManager.default.fileExists(atPath: localURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: partial, to: localURL)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private func uploadViaPowerShell(localURL: URL, remotePath: String, byteCount: Int64) async throws {
        let payload = try Data(contentsOf: localURL)
        guard Int64(payload.count) == byteCount else {
            throw WindowsTransferError.byteCountMismatch(expected: byteCount, actual: Int64(payload.count))
        }
        let arguments = UploadArguments(path: remotePath, base64: payload.base64EncodedString(), expectedByteCount: byteCount)
        let script = try PowerShellScript(source: Self.uploadScript, arguments: arguments)
        _ = try await powerShellChannel.run(script, operation: "UploadFallback")
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
            "get \(Self.quote(remotePath)) \(Self.quote(localURL.path))",
        ])
    }

    func upload(localURL: URL, remotePath: String) async throws {
        try await runBatch(commands: [
            "put \(Self.quote(localURL.path)) \(Self.quote(remotePath))",
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
}

private struct UploadArguments: Encodable {
    let path: String
    let base64: String
    let expectedByteCount: Int64
}

private extension WindowsTransferChannel {
    static let downloadScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Arguments.path))
        """
    )

    static let uploadScript = PowerShellScript.prelude(
        operationBody: """
        param($Arguments)
        $bytes = [Convert]::FromBase64String($Arguments.base64)
        if ($bytes.Length -ne [int64]$Arguments.expectedByteCount) {
            throw "Decoded upload byte count did not match."
        }
        $directory = [System.IO.Path]::GetDirectoryName($Arguments.path)
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        }
        [System.IO.File]::WriteAllBytes($Arguments.path, $bytes)
        [pscustomobject]@{ BytesWritten = [int64]$bytes.Length }
        """
    )
}
