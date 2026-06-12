import CryptoKit
import Foundation

struct RemoteArchitecture: Equatable, Sendable {
    let system: String
    let machine: String

    var isSupported: Bool {
        helperBinaryName != nil
    }

    var helperBinaryName: String? {
        switch (system, machine) {
        case ("Linux", "x86_64"):
            return "detours-server-x86_64-linux"
        case ("Darwin", "x86_64"):
            return "detours-server-x86_64-darwin"
        default:
            return nil
        }
    }
}

struct UnsupportedArchitectureError: Error, Equatable, LocalizedError, Sendable {
    let system: String
    let machine: String

    var errorDescription: String? {
        "Remote helper supports x86_64 Linux and x86_64 macOS only. This host reported \(system) \(machine)."
    }
}

struct RemoteBinaryInfo: Equatable, Sendable {
    let owner: String
    let mode: Int
    let isRegularFile: Bool
}

enum RemoteBinarySecurityIssue: Error, Equatable, Sendable {
    case notRegularFile
    case wrongOwner(expected: String, actual: String)
    case groupOrWorldWritable(mode: Int)
}

enum ServerDeployerError: Error, Equatable, Sendable {
    case bundledBinaryMissing(URL)
    case commandFailed(command: String, status: Int32, stderr: String)
    case invalidRemoteStat(String)
    case insecureInstalledBinary(RemoteBinarySecurityIssue)
    case deployedHashMismatch(expected: String, actual: String?)
}

enum ServerDeploymentReason: Equatable, Sendable {
    case alreadyCurrent
    case missing
    case hashMismatch
}

struct ServerDeploymentResult: Equatable, Sendable {
    let deployed: Bool
    let reason: ServerDeploymentReason
}

protocol ServerDeploymentClient: Sendable {
    func architecture() async throws -> RemoteArchitecture
    func currentUsername() async throws -> String
    func installedBinaryInfo(at path: String) async throws -> RemoteBinaryInfo?
    func installedBinaryHash(at path: String) async throws -> String?
    func prepareInstallDirectory(_ path: String) async throws
    func removePartialBinary(at path: String) async throws
    func uploadBinary(localFile: URL, remotePath: String) async throws
    func finalizeBinary(tempPath: String, finalPath: String) async throws
}

struct SSHServerDeploymentClient: ServerDeploymentClient {
    let sshTarget: String
    var processFactory: @Sendable () -> Process = { Process() }

    func architecture() async throws -> RemoteArchitecture {
        let output = try await run("uname -sm").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw ServerDeployerError.invalidRemoteStat(output)
        }
        return RemoteArchitecture(system: parts[0], machine: parts[1])
    }

    func currentUsername() async throws -> String {
        try await run("id -un").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func installedBinaryInfo(at path: String) async throws -> RemoteBinaryInfo? {
        let output = try await run(
            """
            if [ -e \(path) ]; then \
            owner="$(ls -ld \(path) | awk '{print $3}')"; \
            mode="$(if [ "$(uname -s)" = Darwin ]; then stat -f '%Lp' \(path); else stat -c '%a' \(path); fi)"; \
            type="$(if [ -f \(path) ]; then printf 'regular file'; else printf 'other'; fi)"; \
            printf '%s\\t%s\\t%s\\n' "$owner" "$mode" "$type"; \
            else printf 'missing\\n'; fi
            """
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard output != "missing" else { return nil }

        let fields = output.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, let mode = Int(fields[1], radix: 8) else {
            throw ServerDeployerError.invalidRemoteStat(output)
        }

        return RemoteBinaryInfo(
            owner: fields[0],
            mode: mode,
            isRegularFile: fields[2] == "regular file"
        )
    }

    func installedBinaryHash(at path: String) async throws -> String? {
        let output = try await run(
            """
            if [ -e \(path) ]; then \
            if command -v sha256sum >/dev/null 2>&1; then sha256sum \(path) | awk '{print $1}'; \
            else shasum -a 256 \(path) | awk '{print $1}'; fi; \
            fi
            """
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    func prepareInstallDirectory(_ path: String) async throws {
        _ = try await run("mkdir -p \(path) && chmod 700 \(path)")
    }

    func removePartialBinary(at path: String) async throws {
        _ = try await run("rm -f \(path)")
    }

    func uploadBinary(localFile: URL, remotePath: String) async throws {
        let process = processFactory()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [localFile.path, "\(sshTarget):\(remotePath)"]
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ServerDeployerError.commandFailed(
                command: "scp \(localFile.path) \(sshTarget):\(remotePath)",
                status: process.terminationStatus,
                stderr: stderr
            )
        }
    }

    func finalizeBinary(tempPath: String, finalPath: String) async throws {
        _ = try await run("chmod 700 \(tempPath) && mv -f \(tempPath) \(finalPath) && chmod 700 \(finalPath)")
    }

    private func run(_ command: String) async throws -> String {
        let process = processFactory()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [sshTarget, command]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ServerDeployerError.commandFailed(
                command: command,
                status: process.terminationStatus,
                stderr: String(data: stderr, encoding: .utf8) ?? ""
            )
        }
        return String(data: stdout, encoding: .utf8) ?? ""
    }
}

struct ServerDeployer {
    static let defaultInstallDirectory = "~/.detours-server"
    static let binaryName = "detours-server"

    let client: ServerDeploymentClient
    private let bundledBinaryURLProvider: @Sendable (RemoteArchitecture) -> URL
    let installDirectory: String

    var remoteBinaryPath: String {
        "\(installDirectory)/\(Self.binaryName)"
    }

    var remoteTempPath: String {
        "\(remoteBinaryPath).tmp"
    }

    init(
        client: ServerDeploymentClient,
        bundledBinaryURL: URL,
        installDirectory: String = Self.defaultInstallDirectory
    ) {
        self.client = client
        self.bundledBinaryURLProvider = { _ in bundledBinaryURL }
        self.installDirectory = installDirectory
    }

    init(
        client: ServerDeploymentClient,
        bundledBinaryDirectoryURL: URL,
        installDirectory: String = Self.defaultInstallDirectory
    ) {
        self.client = client
        self.bundledBinaryURLProvider = { architecture in
            let binaryName = architecture.helperBinaryName ?? Self.binaryName
            return bundledBinaryDirectoryURL.appendingPathComponent(binaryName)
        }
        self.installDirectory = installDirectory
    }

    func deployIfNeeded() async throws -> ServerDeploymentResult {
        let architecture = try await client.architecture()
        guard architecture.isSupported else {
            throw UnsupportedArchitectureError(system: architecture.system, machine: architecture.machine)
        }
        let bundledBinaryURL = bundledBinaryURLProvider(architecture)

        guard FileManager.default.fileExists(atPath: bundledBinaryURL.path) else {
            throw ServerDeployerError.bundledBinaryMissing(bundledBinaryURL)
        }

        let expectedHash = try Self.sha256Hex(of: bundledBinaryURL)

        try await client.prepareInstallDirectory(installDirectory)
        try await client.removePartialBinary(at: remoteTempPath)

        let username = try await client.currentUsername()
        let installedInfo = try await client.installedBinaryInfo(at: remoteBinaryPath)

        if let installedInfo {
            try validateInstalledBinary(installedInfo, expectedOwner: username)
            let installedHash = try await client.installedBinaryHash(at: remoteBinaryPath)
            if installedHash == expectedHash {
                return ServerDeploymentResult(deployed: false, reason: .alreadyCurrent)
            }

            return try await deploy(
                bundledBinaryURL: bundledBinaryURL,
                expectedHash: expectedHash,
                expectedOwner: username,
                reason: .hashMismatch
            )
        }

        return try await deploy(
            bundledBinaryURL: bundledBinaryURL,
            expectedHash: expectedHash,
            expectedOwner: username,
            reason: .missing
        )
    }

    static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func deploy(
        bundledBinaryURL: URL,
        expectedHash: String,
        expectedOwner: String,
        reason: ServerDeploymentReason
    ) async throws -> ServerDeploymentResult {
        do {
            try await client.uploadBinary(localFile: bundledBinaryURL, remotePath: remoteTempPath)
            try await client.finalizeBinary(tempPath: remoteTempPath, finalPath: remoteBinaryPath)
        } catch {
            try? await client.removePartialBinary(at: remoteTempPath)
            throw error
        }

        guard let installedInfo = try await client.installedBinaryInfo(at: remoteBinaryPath) else {
            throw ServerDeployerError.deployedHashMismatch(expected: expectedHash, actual: nil)
        }
        try validateInstalledBinary(installedInfo, expectedOwner: expectedOwner)

        let installedHash = try await client.installedBinaryHash(at: remoteBinaryPath)
        guard installedHash == expectedHash else {
            throw ServerDeployerError.deployedHashMismatch(expected: expectedHash, actual: installedHash)
        }

        return ServerDeploymentResult(deployed: true, reason: reason)
    }

    private func validateInstalledBinary(_ info: RemoteBinaryInfo, expectedOwner: String) throws {
        guard info.isRegularFile else {
            throw ServerDeployerError.insecureInstalledBinary(.notRegularFile)
        }

        guard info.owner == expectedOwner else {
            throw ServerDeployerError.insecureInstalledBinary(
                .wrongOwner(expected: expectedOwner, actual: info.owner)
            )
        }

        guard info.mode & 0o022 == 0 else {
            throw ServerDeployerError.insecureInstalledBinary(.groupOrWorldWritable(mode: info.mode))
        }
    }
}
