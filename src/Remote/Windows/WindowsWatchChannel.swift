import Foundation

enum WindowsWatchChannelError: Error, Equatable, LocalizedError {
    case missingChannel
    case invalidFrame(String)
    case remoteError(String)

    var errorDescription: String? {
        switch self {
        case .missingChannel:
            return "Windows watch channel is not available."
        case .invalidFrame(let message), .remoteError(let message):
            return message
        }
    }
}

actor WindowsWatchChannel {
    private struct Request: Encodable {
        let id: UInt64
        let command: String
        let watchID: UUID?
        let path: String?
    }

    private struct Response: Decodable {
        let type: String
        let id: UInt64?
        let watchID: UUID?
        let path: String?
        let error: String?
    }

    private let hostID: UUID
    private let transport: any PowerShellChannelTransport
    private var isStarted = false
    private var nextRequestID: UInt64 = 1
    private var readTask: Task<Void, Never>?
    private var pending: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var callbacks: [UUID: @Sendable (Location) -> Void] = [:]
    private var watches: [UUID: FileProviderWatch] = [:]

    init(
        hostID: UUID,
        sshTarget: String,
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust()
    ) {
        self.hostID = hostID
        transport = PowerShellProcessTransport(
            sshTarget: sshTarget,
            controlDirectory: controlDirectory,
            hostTrust: hostTrust
        )
    }

    init(hostID: UUID, transport: any PowerShellChannelTransport) {
        self.hostID = hostID
        self.transport = transport
    }

    func watch(
        _ location: Location,
        nativePath: String,
        onChange: @escaping @Sendable (Location) -> Void
    ) async throws -> FileProviderWatch {
        try await startIfNeeded()
        let watch = FileProviderWatch(id: UUID(), location: location)
        callbacks[watch.id] = onChange
        watches[watch.id] = watch
        do {
            try await send(command: "watch", watchID: watch.id, path: nativePath)
            return watch
        } catch {
            callbacks.removeValue(forKey: watch.id)
            watches.removeValue(forKey: watch.id)
            throw error
        }
    }

    func unwatch(_ watch: FileProviderWatch) async {
        callbacks.removeValue(forKey: watch.id)
        watches.removeValue(forKey: watch.id)
        // Windows OpenSSH on this host does not reliably deliver a second stdin
        // frame to the long-lived PowerShell watcher process. Drop callbacks
        // locally and terminate the watcher process when the final watch closes.
        if watches.isEmpty {
            await stop()
        }
    }

    func stop() async {
        readTask?.cancel()
        readTask = nil
        pending.values.forEach { $0.resume(throwing: WindowsWatchChannelError.remoteError("Windows watch channel stopped.")) }
        pending.removeAll()
        callbacks.removeAll()
        watches.removeAll()
        await transport.stop()
        isStarted = false
    }

    private func startIfNeeded() async throws {
        guard !isStarted else { return }
        try await transport.start(dispatcherBase64: Self.dispatcherBase64())
        isStarted = true
        readTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop()
        }
    }

    private func send(command: String, watchID: UUID?, path: String?) async throws {
        let requestID = nextRequestID
        nextRequestID += 1
        let request = Request(id: requestID, command: command, watchID: watchID, path: path)
        let payload = try JSONEncoder.detoursWindows.encode(request)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[requestID] = continuation
            Task {
                do {
                    try await transport.sendFrame(try RPCStreamHandler.encodeFrame(payload))
                } catch {
                    failPendingRequest(requestID, error: error)
                }
            }
        }
    }

    private func failPendingRequest(_ requestID: UInt64, error: Error) {
        pending.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                let frame = try await transport.readFrame()
                try await receive(frame)
            } catch {
                failAllPending(error)
                await stop()
                return
            }
        }
    }

    private func receive(_ frame: Data) async throws {
        let response = try JSONDecoder.detoursWindows.decode(Response.self, from: frame)
        switch response.type {
        case "ack":
            guard let id = response.id else { throw WindowsWatchChannelError.invalidFrame("Missing ack id.") }
            pending.removeValue(forKey: id)?.resume(returning: ())
        case "error":
            guard let id = response.id else { throw WindowsWatchChannelError.invalidFrame("Missing error id.") }
            pending.removeValue(forKey: id)?.resume(
                throwing: WindowsWatchChannelError.remoteError(response.error ?? "Windows watch request failed.")
            )
        case "event":
            guard let watchID = response.watchID, let nativePath = response.path else {
                throw WindowsWatchChannelError.invalidFrame("Missing watch event fields.")
            }
            let location = (try? WindowsPath.location(fromNative: nativePath, hostID: hostID))
                ?? watches[watchID]?.location
            if let location {
                callbacks[watchID]?(location)
            }
        default:
            throw WindowsWatchChannelError.invalidFrame("Unknown watch frame type: \(response.type)")
        }
    }

    private func failAllPending(_ error: Error) {
        pending.values.forEach { $0.resume(throwing: error) }
        pending.removeAll()
    }

    static func dispatcherBase64() -> String {
        Data(dispatcherScript.utf16LittleEndianBytes).base64EncodedString()
    }

    private static let dispatcherScript = #"""
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $stdinStream = [Console]::OpenStandardInput()
    $stdoutStream = [Console]::OpenStandardOutput()
    $writeLock = New-Object object
    $watchers = @{}

    function Read-Exact([int]$Count) {
        $buffer = [byte[]]::new($Count)
        $offset = 0
        while ($offset -lt $Count) {
            $read = $stdinStream.Read($buffer, $offset, $Count - $offset)
            if ($read -le 0) {
                if ($offset -eq 0) { return $null }
                throw "Unexpected end of Windows watch request stream."
            }
            $offset += $read
        }
        return $buffer
    }

    function Write-Frame([string]$Json) {
        [System.Threading.Monitor]::Enter($writeLock)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
            $len = [System.BitConverter]::GetBytes([uint32]$bytes.Length)
            if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($len) }
            $stdoutStream.Write($len, 0, 4)
            $stdoutStream.Write($bytes, 0, $bytes.Length)
            $stdoutStream.Flush()
        } finally {
            [System.Threading.Monitor]::Exit($writeLock)
        }
    }

    function Send-Ack([uint64]$Id) {
        Write-Frame (@{ type = 'ack'; id = $Id } | ConvertTo-Json -Compress)
    }

    function Send-Error([uint64]$Id, [string]$Message) {
        Write-Frame (@{ type = 'error'; id = $Id; error = $Message } | ConvertTo-Json -Compress)
    }

    function Register-Watch($Request) {
        $watchID = [string]$Request.watchID
        $path = [string]$Request.path
        $watcher = [System.IO.FileSystemWatcher]::new($path)
        $watcher.IncludeSubdirectories = $false
        $watcher.EnableRaisingEvents = $true
        $subscriptions = @()
        foreach ($eventName in @('Changed', 'Created', 'Deleted', 'Renamed')) {
            $sourceID = "detours-$watchID-$eventName"
            $subscriptions += Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceID -MessageData $watchID
        }
        $watchers[$watchID] = @{
            Watcher = $watcher
            Subscriptions = $subscriptions
        }
    }

    function Unregister-Watch([string]$WatchID) {
        if (-not $watchers.ContainsKey($WatchID)) { return }
        $entry = $watchers[$WatchID]
        foreach ($subscription in $entry.Subscriptions) {
            Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
            Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
        }
        $entry.Watcher.EnableRaisingEvents = $false
        $entry.Watcher.Dispose()
        $watchers.Remove($WatchID)
    }

    function Send-WatchEvent($EventRecord) {
        $eventPath = $EventRecord.SourceEventArgs.FullPath
        Write-Frame (@{
            type = 'event'
            watchID = [string]$EventRecord.MessageData
            path = [string]$eventPath
        } | ConvertTo-Json -Compress)
        Remove-Event -EventIdentifier $EventRecord.EventIdentifier -ErrorAction SilentlyContinue
    }

    try {
        while ($true) {
            $lengthBytes = Read-Exact 4
            if ($null -eq $lengthBytes) { break }
            if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($lengthBytes) }
            $length = [System.BitConverter]::ToUInt32($lengthBytes, 0)
            $payloadBytes = Read-Exact ([int]$length)
            $request = [System.Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json
            try {
                switch ([string]$request.command) {
                    'watch' {
                        Register-Watch $request
                        Send-Ack ([uint64]$request.id)
                        while ($watchers.Count -gt 0) {
                            $eventRecord = Wait-Event -Timeout 1
                            if ($null -ne $eventRecord) { Send-WatchEvent $eventRecord }
                        }
                    }
                    'unwatch' { Unregister-Watch ([string]$request.watchID); Send-Ack ([uint64]$request.id) }
                    default { throw "Unknown Windows watch command: $($request.command)" }
                }
            } catch {
                Send-Error ([uint64]$request.id) $_.Exception.Message
            }
        }
    } finally {
        foreach ($watchID in @($watchers.Keys)) {
            Unregister-Watch $watchID
        }
    }
    """#
}

private extension String {
    var utf16LittleEndianBytes: [UInt8] {
        Array(utf16.flatMap { codeUnit in
            [UInt8(codeUnit & 0x00ff), UInt8(codeUnit >> 8)]
        })
    }
}
