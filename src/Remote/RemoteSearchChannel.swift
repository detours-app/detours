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
    private let session: RemoteHostSession?

    init(
        sshTarget: String,
        remoteCommand: String = "~/.detours-server/detours-server",
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust(),
        session: RemoteHostSession? = nil
    ) {
        self.sshTarget = sshTarget
        self.remoteCommand = remoteCommand
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.session = session
        _ = BrokenPipe.ignored
    }

    nonisolated func search(query: Data, cap: Int64) -> AsyncThrowingStream<[RemoteFindMatch], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lifetime = try await session?.acquireLifetime(.reader)
                    defer { lifetime?.release() }
                    let ready = try await session?.ensureReady()
                    try Task.checkCancellation()
                    for try await matches in searchVerifiedConnection(query: query, cap: cap) {
                        try Task.checkCancellation()
                        if let ready { try await session?.requireGeneration(ready.generation) }
                        continuation.yield(matches)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated private func searchVerifiedConnection(query: Data, cap: Int64) -> AsyncThrowingStream<[RemoteFindMatch], Error> {
        let arguments = sshArguments()
        let hostTrust = self.hostTrust
        let session = self.session
        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            let worker = RemoteProcessWorker(process: process)
            let body: @Sendable (RemoteProcessWorker) throws -> Void = { worker in
                try hostTrust.prepareKnownHostsFile()
                try worker.start()
                let request = RPCEnvelope(id: 1, kind: .request, messageType: "Find", sequence: 0, isFinal: true,
                    payload: try RPCMessage.find(query: query, cap: cap).binaryEncoded())
                try worker.write(RPCStreamHandler.encodeFrame(request.encodedPayload()))
                worker.closeInput()
                var progressDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                while true {
                    let envelope = try RPCEnvelope(encodedPayload: worker.readFrame(timeout: ContinuousClock.now.duration(to: progressDeadline)))
                    guard envelope.id == 1 else { continue }
                    if envelope.kind == .error { throw SSHRemoteRPCClient.decodeError(envelope.payload) }
                    guard envelope.kind == .response else { continue }
                    let matches = try RemoteFindCodec.decode(envelope.payload)
                    if !matches.isEmpty {
                        continuation.yield(matches)
                        progressDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                    }
                    if envelope.isFinal { break }
                }
                let status = try worker.waitForExit()
                guard status == 0 else {
                    worker.finishDiagnostics()
                    throw RemoteTransferError.processFailed(worker.diagnostics)
                }
            }
            let task = Task {
                do {
                    if let session {
                        try await session.performOwnedWorker(worker, kind: .reader, body: body)
                    } else { try await worker.perform(body) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
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
