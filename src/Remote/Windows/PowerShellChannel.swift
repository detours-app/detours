import Darwin
import Foundation

enum PowerShellChannelError: Error, Equatable, LocalizedError {
    case responseIDMismatch(expected: UInt64, actual: UInt64)
    case remoteError(String)
    case invalidResponse(String)
    case processFailed(String)
    case timeout(String)
    case unexpectedEOF

    var errorDescription: String? {
        switch self {
        case .responseIDMismatch:
            return "The Windows host sent a reply that didn't match the request."
        case .remoteError:
            return "The Windows host reported an error."
        case .invalidResponse:
            return "The Windows host sent an unexpected reply."
        case .processFailed:
            return "The connection to the Windows host failed."
        case .timeout:
            return "The Windows host stopped responding."
        case .unexpectedEOF:
            return "The connection to the Windows host closed unexpectedly."
        }
    }

    var failureReason: String? {
        switch self {
        case let .remoteError(message), let .processFailed(message):
            // The host's own message (or the underlying ssh error) is the useful detail.
            return message.isEmpty ? nil : message
        case .responseIDMismatch, .invalidResponse, .timeout, .unexpectedEOF:
            return nil
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .remoteError:
            return "Check the item and your permissions on the host, then try again."
        case .processFailed:
            return "Check that the host is reachable over SSH, then try again."
        case .responseIDMismatch, .invalidResponse, .timeout, .unexpectedEOF:
            return "Reconnect to the host and try again."
        }
    }
}

protocol PowerShellChannelTransport: Sendable {
    func start(dispatcherBase64: String) async throws
    func sendFrame(_ frame: Data) async throws
    func readFrame() async throws -> Data
    func stop() async
    /// Tears down the shared SSH control master for this host. The command, transfer, and
    /// watch channels all multiplex over one ControlPath socket, so closing it ends every
    /// session for the host at once. Transports without a real control master no-op.
    func closeControlConnection() async
}

extension PowerShellChannelTransport {
    func closeControlConnection() async {}
}

actor PowerShellChannel: RemoteConnectionHandle {
    private struct Request: Encodable {
        let id: UInt64
        let operation: String
        let script: String
        let argumentsJSON: String
    }

    private struct Response: Decodable {
        let id: UInt64
        let ok: Bool
        let resultJSON: String?
        let error: String?
    }

    private let transport: any PowerShellChannelTransport
    private let hostID: UUID?
    private let idleTimeout: TimeInterval
    private var nextRequestID: UInt64 = 1
    private var isStarted = false
    private var activePaneCount = 0
    private var inFlightOperationCount = 0
    private var idleDisconnectTask: Task<Void, Never>?

    // Serializes requests on the single shared oneShot transport: the actor releases its
    // lock at every `await transport.*`, so without this gate a second concurrent `run()`
    // could start its send/read while another is mid-flight and collide on the process.
    private var isProcessingRequest = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    private var state: SSHConnectionState = .disconnected {
        didSet { publishStateChange(from: oldValue, to: state) }
    }

    init(
        hostID: UUID,
        sshTarget: String,
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust(),
        idleTimeout: TimeInterval = 5 * 60
    ) {
        self.hostID = hostID
        self.idleTimeout = idleTimeout
        transport = PowerShellProcessTransport(
            sshTarget: sshTarget,
            controlDirectory: controlDirectory,
            hostTrust: hostTrust,
            executionMode: .oneShot
        )
    }

    init(transport: any PowerShellChannelTransport, hostID: UUID? = nil, idleTimeout: TimeInterval = 5 * 60) {
        self.transport = transport
        self.hostID = hostID
        self.idleTimeout = idleTimeout
    }

    func run(_ script: PowerShellScript, operation: String) async throws -> Data {
        await acquireRequestSlot()
        beginInFlightOperation()
        defer {
            endInFlightOperation()
            releaseRequestSlot()
        }
        do {
            return try await sendAndReceive(script, operation: operation)
        } catch let error as PowerShellChannelError where Self.isRemoteOperationError(error) {
            // An operation-level error from a responsive host is not a connection drop; surface
            // it to the caller without restarting or publishing a failed state.
            throw error
        } catch {
            // A transient transport failure (a oneShot ssh that lost a race on the shared
            // master, say) gets one quiet re-establish-and-retry before it is treated as a
            // real drop, so a single hiccup never pauses the file-operation queue.
            isStarted = false
            await transport.stop()
            do {
                return try await sendAndReceive(script, operation: operation)
            } catch let retryError as PowerShellChannelError where Self.isRemoteOperationError(retryError) {
                throw retryError
            } catch {
                await restartAfterProtocolFailure(reason: .transport(error.localizedDescription))
                throw error
            }
        }
    }

    private func sendAndReceive(_ script: PowerShellScript, operation: String) async throws -> Data {
        try await startIfNeeded()
        let requestID = nextRequestID
        nextRequestID += 1

        let request = Request(
            id: requestID,
            operation: operation,
            script: script.sourceBase64UTF16LE,
            argumentsJSON: script.argumentsJSON
        )
        let payload = try JSONEncoder.detoursWindows.encode(request)
        try await transport.sendFrame(try RPCStreamHandler.encodeFrame(payload))
        let responsePayload = try await transport.readFrame()
        let response = try JSONDecoder.detoursWindows.decode(Response.self, from: responsePayload)
        guard response.id == requestID else {
            throw PowerShellChannelError.responseIDMismatch(expected: requestID, actual: response.id)
        }
        // A complete framed reply means the host connection is live, even if the operation it
        // carried failed.
        transition(to: .connected)
        guard response.ok else {
            throw PowerShellChannelError.remoteError(response.error ?? "PowerShell operation failed.")
        }
        return Data((response.resultJSON ?? "null").utf8)
    }

    func setActivePaneCount(_ count: Int) async {
        activePaneCount = max(0, count)
        scheduleIdleDisconnectIfNeeded()
    }

    func forceReconnect() async throws {
        // Clear state before the teardown await so a concurrent request cannot observe a
        // stale "started" flag while the transport is stopping.
        isStarted = false
        cancelIdleDisconnect()
        transition(to: .connecting)
        await transport.stop()
        try await startIfNeeded()
        // Verify reachability with a trivial request so a successful manual reconnect
        // publishes .connected and resumes any paused queue operation.
        _ = try await run(PowerShellScript(source: "$true"), operation: "ReconnectCheck")
    }

    func disconnect() async {
        isStarted = false
        activePaneCount = 0
        inFlightOperationCount = 0
        cancelIdleDisconnect()
        await transport.stop()
        // Close the shared control master so the host's watch and transfer sessions
        // multiplexed over it do not linger after the channel goes away (e.g. on app quit).
        await transport.closeControlConnection()
        transition(to: .disconnected)
    }

    /// Exercises the same channel teardown and failed-state publication as an unexpected
    /// transport loss. This is reached only through the runtime-gated UI-test command seam.
    func interruptForUITest() async {
        isStarted = false
        cancelIdleDisconnect()
        await transport.stop()
        await transport.closeControlConnection()
        transition(to: .failed(reason: .transport("UI test connection dropped")))
    }

    #if DEBUG
    func isStartedForTesting() -> Bool {
        isStarted
    }

    func inFlightOperationCountForTesting() -> Int {
        inFlightOperationCount
    }

    func simulateConnectedForTesting() {
        transition(to: .connected)
    }
    #endif

    private func beginInFlightOperation() {
        inFlightOperationCount += 1
        cancelIdleDisconnect()
    }

    private func endInFlightOperation() {
        inFlightOperationCount = max(0, inFlightOperationCount - 1)
        scheduleIdleDisconnectIfNeeded()
    }

    private var hasIdleBlockers: Bool {
        activePaneCount > 0 || inFlightOperationCount > 0
    }

    private func scheduleIdleDisconnectIfNeeded() {
        cancelIdleDisconnect()
        guard isStarted, !hasIdleBlockers else { return }
        let timeout = idleTimeout
        idleDisconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            await self?.disconnectForIdleIfStillInactive()
        }
    }

    private func cancelIdleDisconnect() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = nil
    }

    private func disconnectForIdleIfStillInactive() async {
        guard isStarted, !hasIdleBlockers else { return }
        idleDisconnectTask = nil
        // Idle teardown is silent: the connection logically still exists (the next request
        // transparently reconnects), so it is not surfaced as a drop.
        isStarted = false
        await transport.stop()
    }

    /// True for an error the host returned about the operation itself (it responded, so the
    /// connection is healthy), as opposed to a transport/protocol failure that is a real drop.
    private static func isRemoteOperationError(_ error: PowerShellChannelError) -> Bool {
        if case .remoteError = error { return true }
        return false
    }

    private func transition(to newState: SSHConnectionState) {
        guard state != newState else { return }
        state = newState
    }

    private func publishStateChange(from oldState: SSHConnectionState, to newState: SSHConnectionState) {
        guard let hostID else { return }
        Task { @MainActor in
            RemoteConnectionStateStore.shared.setState(newState, for: hostID, oldState: oldState)
        }
    }

    /// FIFO mutex over the shared transport: each request fully completes its send and read
    /// before the next begins. Ownership passes directly to the next waiter on release.
    private func acquireRequestSlot() async {
        if !isProcessingRequest {
            isProcessingRequest = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        if requestWaiters.isEmpty {
            isProcessingRequest = false
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    private func startIfNeeded() async throws {
        guard !isStarted else { return }
        try await transport.start(dispatcherBase64: Self.dispatcherBase64)
        isStarted = true
    }

    private func restartAfterProtocolFailure(reason: SSHConnectionFailureReason) async {
        // Clear the started flag before the teardown await (T13), publish the drop, then
        // re-arm if work is still pending so the next request reconnects transparently.
        isStarted = false
        cancelIdleDisconnect()
        transition(to: .failed(reason: reason))
        await transport.stop()
        if hasIdleBlockers {
            try? await startIfNeeded()
        }
    }

    static let dispatcherBase64 = dispatcherScript.utf16LittleEndianData.base64EncodedString()

    private static let dispatcherScript = #"""
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    # Use file streams for SSH pipes, as PowerShell's SSHProcessMediator does.
    # https://github.com/PowerShell/PowerShell/issues/14478
    Add-Type -TypeDefinition @'
    using System;
    using System.IO;
    using System.Runtime.InteropServices;
    using Microsoft.Win32.SafeHandles;
    public static class DetoursStandardStreams {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int kind);
        public static FileStream Open(int kind, FileAccess access) {
            var handle = new SafeFileHandle(GetStdHandle(kind), false);
            if (handle.IsInvalid) { throw new IOException("SSH standard stream is unavailable."); }
            return new FileStream(handle, access, 4096, false);
        }
    }
    '@
    $stdinStream = [DetoursStandardStreams]::Open(-10, [System.IO.FileAccess]::Read)
    $stdoutStream = [DetoursStandardStreams]::Open(-11, [System.IO.FileAccess]::Write)

    function Read-Exact([int]$Count) {
        $buffer = [byte[]]::new($Count)
        $offset = 0
        while ($offset -lt $Count) {
            $read = $stdinStream.Read($buffer, $offset, $Count - $offset)
            if ($read -le 0) {
                if ($offset -eq 0) { return $null }
                throw "Unexpected end of PowerShell request stream."
            }
            $offset += $read
        }
        return $buffer
    }

    function Write-Frame([string]$Json) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $len = [System.BitConverter]::GetBytes([uint32]$bytes.Length)
        if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($len) }
        $stdoutStream.Write($len, 0, 4)
        $stdoutStream.Write($bytes, 0, $bytes.Length)
        $stdoutStream.Flush()
    }

    while ($true) {
        $lengthBytes = Read-Exact 4
        if ($null -eq $lengthBytes) { break }
        if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($lengthBytes) }
        $length = [System.BitConverter]::ToUInt32($lengthBytes, 0)
        $payloadBytes = Read-Exact ([int]$length)
        $request = [System.Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json
        try {
            $script = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($request.script))
            $arguments = $request.argumentsJSON | ConvertFrom-Json
            $result = & ([scriptblock]::Create($script)) $arguments
            $resultJson = $result | ConvertTo-Json -Compress -Depth 100
            if ($null -eq $resultJson) {
                $resultJson = 'null'
            } else {
                $resultJson = [string]$resultJson
            }
            Write-Frame (@{ id = [uint64]$request.id; ok = $true; resultJSON = $resultJson } | ConvertTo-Json -Compress -Depth 4)
        } catch {
            Write-Frame (@{ id = [uint64]$request.id; ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress -Depth 4)
        }
    }
    """#
}
