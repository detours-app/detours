import Foundation

/// Runs a whole-host name search as its own short-lived `ssh` process (reusing the connection's
/// control master), independent of the persistent RPC connection. This keeps a long search from
/// blocking other operations, and lets the client abandon it instantly: cancelling the returned
/// stream terminates the process, so a new keystroke never piles up behind an in-flight search.
actor RemoteSearchChannel {
    private let sshTarget: String
    private let remoteCommand: String
    private let controlDirectory: URL
    private let hostTrust: SSHHostTrust

    init(
        sshTarget: String,
        remoteCommand: String = "~/.detours-server/detours-server",
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust()
    ) {
        self.sshTarget = sshTarget
        self.remoteCommand = remoteCommand
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
    }

    nonisolated func search(query: Data, cap: Int64) -> AsyncThrowingStream<[RemoteFindMatch], Error> {
        let arguments = sshArguments()
        let hostTrust = self.hostTrust
        return AsyncThrowingStream { continuation in
            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try hostTrust.prepareKnownHostsFile()
                    try process.run()

                    let request = RPCEnvelope(
                        id: 1,
                        kind: .request,
                        messageType: "Find",
                        sequence: 0,
                        isFinal: true,
                        payload: try RPCMessage.find(query: query, cap: cap).binaryEncoded()
                    )
                    stdin.fileHandleForWriting.write(try RPCStreamHandler.encodeFrame(request.encodedPayload()))
                    try? stdin.fileHandleForWriting.close()

                    var handler = RPCStreamHandler()
                    let output = stdout.fileHandleForReading
                    while true {
                        let chunk = output.availableData
                        if chunk.isEmpty { break } // EOF
                        for frame in try handler.append(chunk) {
                            let envelope = try RPCEnvelope(encodedPayload: frame)
                            guard envelope.id == 1 else { continue }
                            if envelope.kind == .error {
                                throw RemoteFileProviderError.invalidResponse("Remote search failed")
                            }
                            guard envelope.kind == .response else { continue }
                            let matches = try RemoteFindCodec.decode(envelope.payload)
                            if !matches.isEmpty {
                                continuation.yield(matches)
                            }
                            if envelope.isFinal {
                                process.waitUntilExit()
                                continuation.finish()
                                return
                            }
                        }
                    }

                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.finish()
                    } else {
                        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        continuation.finish(throwing: RemoteFileProviderError.invalidResponse(
                            message.isEmpty ? "Remote search exited \(process.terminationStatus)" : message
                        ))
                    }
                } catch {
                    if process.isRunning {
                        process.terminate()
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private nonisolated func sshArguments() -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
        ] + hostTrust.sshArguments + [
            sshTarget,
            remoteCommand,
        ]
    }
}
