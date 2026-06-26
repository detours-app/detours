import Foundation

protocol RemoteHostKindProbeClient: Sendable {
    func run(_ command: String) async throws -> String
}

struct RemoteHostKindProbe: Sendable {
    let client: any RemoteHostKindProbeClient

    func probe() async -> RemoteHostKind {
        if let output = try? await client.run(Self.windowsProbeCommand()),
           Self.isWindowsProbeOutput(output) {
            return .windows
        }
        return .unix
    }

    func resolve(cachedKind: RemoteHostKind?) async -> RemoteHostKind {
        switch cachedKind {
        case .windows:
            return .windows
        case .unix, nil:
            return await probe()
        }
    }

    static func windowsProbeCommand() -> String {
        let script = """
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        if ($PSVersionTable.PSEdition -or $PSVersionTable.PSVersion) {
            "DETOURS_WINDOWS_PROBE\t$([System.Environment]::OSVersion.Platform)"
        }
        """
        let encoded = script.utf16LittleEndianData.base64EncodedString()
        return "powershell.exe -NoProfile -NonInteractive -EncodedCommand \(encoded)"
    }

    static func isWindowsProbeOutput(_ output: String) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                return parts.count == 2
                    && parts[0] == "DETOURS_WINDOWS_PROBE"
                    && parts[1].lowercased().contains("win")
            }
    }
}

struct RemoteConnectionRoute: Equatable, Sendable {
    let kind: RemoteHostKind

    var deploysHelper: Bool {
        kind == .unix
    }

    var usesWindowsProvider: Bool {
        kind == .windows
    }
}

struct SSHRemoteHostKindProbeClient: RemoteHostKindProbeClient {
    let sshTarget: String
    var processFactory: @Sendable () -> Process = { Process() }

    func run(_ command: String) async throws -> String {
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
