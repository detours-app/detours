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

/// Multiplexes one watcher process per watch. Windows OpenSSH does not reliably deliver a
/// second stdin frame to a long-lived process, so rather than registering many watches on a
/// single dispatcher we run an independent process per watch (each keyed by its watch id) and
/// fan their event streams back through this actor.
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
        let pid: Int?
    }

    private struct WatchEntry {
        let generation: UUID
        let transport: any PowerShellChannelTransport
        let readTask: Task<Void, Never>
        let onChange: @Sendable (Location) -> Void
        let location: Location
        let watcherPID: Int?
    }

    private struct Registration {
        let location: Location
        let nativePath: String
        let onChange: @Sendable (Location) -> Void
    }

    private let hostID: UUID
    private let transportFactory: @Sendable () -> any PowerShellChannelTransport
    /// Kills a watcher PowerShell on the host by PID. A watcher whose ssh is torn down does not
    /// notice it (Windows sshd keeps its stdin/stdout alive, so neither EOF nor a failed write
    /// ever fires), so the only reliable teardown is an explicit kill over a fresh command.
    private let watcherKiller: (@Sendable (Int) async -> Void)?
    private var watchers: [UUID: WatchEntry] = [:]
    private var registrations: [UUID: Registration] = [:]
    private var workerEpoch = UUID()
    private var pendingWorkers: [UUID: (generation: UUID, transport: any PowerShellChannelTransport)] = [:]
    private var recentEventTimestamps: [String: Date] = [:]
    private static let dedupWindow: TimeInterval = 0.5

    init(
        hostID: UUID,
        sshTarget: String,
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust()
    ) {
        self.hostID = hostID
        self.transportFactory = {
            PowerShellProcessTransport(
                sshTarget: sshTarget,
                controlDirectory: controlDirectory,
                hostTrust: hostTrust,
                executionMode: .persistent
            )
        }
        self.watcherKiller = { pid in
            await Self.killRemoteProcess(
                pid: pid, sshTarget: sshTarget, controlDirectory: controlDirectory, hostTrust: hostTrust
            )
        }
    }

    init(hostID: UUID, transportFactory: @escaping @Sendable () -> any PowerShellChannelTransport) {
        self.hostID = hostID
        self.transportFactory = transportFactory
        self.watcherKiller = nil
    }

    func watch(
        _ location: Location,
        nativePath: String,
        onChange: @escaping @Sendable (Location) -> Void
    ) async throws -> FileProviderWatch {
        let id = UUID()
        registrations[id] = Registration(location: location, nativePath: nativePath, onChange: onChange)
        do {
            try await startWatch(id: id)
            return FileProviderWatch(id: id, location: location)
        } catch {
            registrations.removeValue(forKey: id)
            throw error
        }
    }

    private func startWatch(id: UUID) async throws {
        guard let registration = registrations[id] else { throw CancellationError() }
        let generation = UUID()
        let epoch = workerEpoch
        let transport = transportFactory()
        pendingWorkers[id] = (generation, transport)
        defer {
            if pendingWorkers[id]?.generation == generation { pendingWorkers.removeValue(forKey: id) }
        }
        do {
            try await transport.start(dispatcherBase64: Self.dispatcherBase64)
            let request = Request(id: 1, command: "watch", watchID: id, path: registration.nativePath)
            try await transport.sendFrame(try RPCStreamHandler.encodeFrame(JSONEncoder.detoursWindows.encode(request)))
            let ackFrame = try await transport.readFrame()
            let ack = try JSONDecoder.detoursWindows.decode(Response.self, from: ackFrame)
            guard ack.type == "ack" else {
                throw WindowsWatchChannelError.remoteError(ack.error ?? "Windows watch was not acknowledged.")
            }
            try Task.checkCancellation()
            guard registrations[id] != nil, workerEpoch == epoch else { throw CancellationError() }
            let readTask = Task { [weak self] in
                guard let self else { return }
                await self.eventLoop(watchID: id, generation: generation, transport: transport)
            }
            watchers[id] = WatchEntry(
                generation: generation, transport: transport, readTask: readTask, onChange: registration.onChange,
                location: registration.location, watcherPID: ack.pid
            )
        } catch {
            await transport.stop()
            throw error
        }
    }

    func unwatch(_ watch: FileProviderWatch) async {
        registrations.removeValue(forKey: watch.id)
        guard let entry = watchers.removeValue(forKey: watch.id) else { return }
        forgetEvents(for: watch.id)
        entry.readTask.cancel()
        await entry.transport.stop()
        if let pid = entry.watcherPID { await watcherKiller?(pid) }
    }

    func stop() async {
        registrations.removeAll()
        await invalidateWorkers()
    }

    func reregisterAfterReconnect() async throws {
        await invalidateWorkers()
        for id in Array(registrations.keys) {
            guard registrations[id] != nil else { continue }
            try await startWatch(id: id)
        }
    }

    func invalidateWorkers() async {
        workerEpoch = UUID()
        let pending = Array(pendingWorkers.values)
        pendingWorkers.removeAll()
        let current = watchers
        watchers.removeAll()
        recentEventTimestamps.removeAll()
        for entry in pending { await entry.transport.stop() }
        for (_, entry) in current {
            entry.readTask.cancel()
            await entry.transport.stop()
            if let pid = entry.watcherPID { await watcherKiller?(pid) }
        }
    }

    private func eventLoop(watchID: UUID, generation: UUID, transport: any PowerShellChannelTransport) async {
        while !Task.isCancelled {
            do {
                let frame = try await transport.readFrame()
                guard watchers[watchID]?.generation == generation else { return }
                let response = try JSONDecoder.detoursWindows.decode(Response.self, from: frame)
                switch response.type {
                case "event":
                    deliverEvent(watchID: watchID, nativePath: response.path)
                case "heartbeat":
                    // Keepalive only: it keeps a quiet directory's stream from tripping the
                    // read timeout, but is not a user-visible change.
                    continue
                case "error":
                    handleWatchDropped(watchID)
                    return
                default:
                    continue
                }
            } catch {
                guard watchers[watchID]?.generation == generation else { return }
                handleWatchDropped(watchID)
                return
            }
        }
    }

    private func deliverEvent(watchID: UUID, nativePath: String?) {
        guard let entry = watchers[watchID], let nativePath else { return }
        let eventKey = "\(watchID.uuidString)|\(nativePath)"
        let now = Date()
        if let last = recentEventTimestamps[eventKey], now.timeIntervalSince(last) < Self.dedupWindow {
            return
        }
        recentEventTimestamps[eventKey] = now
        recentEventTimestamps = recentEventTimestamps.filter { now.timeIntervalSince($0.value) < Self.dedupWindow }
        let location = (try? WindowsPath.location(fromNative: nativePath, hostID: hostID)) ?? entry.location
        entry.onChange(location)
    }

    private func handleWatchDropped(_ watchID: UUID) {
        guard let entry = watchers.removeValue(forKey: watchID) else { return }
        forgetEvents(for: watchID)
        let killer = watcherKiller
        Task {
            await entry.transport.stop()
            if let pid = entry.watcherPID { await killer?(pid) }
        }
        // Surface the drop as a change so the file list reloads and re-arms its watch rather
        // than leaving a stale record that blocks re-watching the directory.
        entry.onChange(entry.location)
    }

    /// Kills a remote watcher by PID over a fresh ssh command (the command path works even when
    /// the watcher's own connection is wedged). Bounded and off-actor so it can never stall.
    private static func killRemoteProcess(
        pid: Int,
        sshTarget: String,
        controlDirectory: URL,
        hostTrust: SSHHostTrust
    ) async {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlDirectory.path)/%C",
                "-o", "ControlPersist=300",
            ] + hostTrust.sshArguments + [
                sshTarget,
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Stop-Process -Id \(pid) -Force -ErrorAction SilentlyContinue",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }.value
    }

    private func forgetEvents(for watchID: UUID) {
        recentEventTimestamps = recentEventTimestamps.filter { !$0.key.hasPrefix("\(watchID.uuidString)|") }
    }

    static let dispatcherBase64 = dispatcherScript.utf16LittleEndianData.base64EncodedString()

    private static let dispatcherScript = #"""
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $stdinStream = [Console]::OpenStandardInput()
    $stdoutStream = [Console]::OpenStandardOutput()

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
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $len = [System.BitConverter]::GetBytes([uint32]$bytes.Length)
        if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($len) }
        $stdoutStream.Write($len, 0, 4)
        $stdoutStream.Write($bytes, 0, $bytes.Length)
        $stdoutStream.Flush()
    }

    # One watch per process: read the single registration frame, then stream events. Later
    # stdin frames are never expected, sidestepping the unreliable second-frame delivery.
    $lengthBytes = Read-Exact 4
    if ($null -eq $lengthBytes) { return }
    if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($lengthBytes) }
    $length = [System.BitConverter]::ToUInt32($lengthBytes, 0)
    $payloadBytes = Read-Exact ([int]$length)
    $request = [System.Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json
    $watchID = [string]$request.watchID
    $path = [string]$request.path

    try {
        $watcher = [System.IO.FileSystemWatcher]::new($path)
        $watcher.IncludeSubdirectories = $false
        $watcher.EnableRaisingEvents = $true
        foreach ($eventName in @('Changed', 'Created', 'Deleted', 'Renamed')) {
            Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier "detours-$eventName" -MessageData $watchID | Out-Null
        }
        Write-Frame (@{ type = 'ack'; id = [uint64]$request.id; pid = $PID } | ConvertTo-Json -Compress)
    } catch {
        Write-Frame (@{ type = 'error'; id = [uint64]$request.id; error = $_.Exception.Message } | ConvertTo-Json -Compress)
        return
    }

    # Watch stdin asynchronously: when the SSH session drops, the read completes at EOF and the
    # process exits at once, instead of lingering on the host until a heartbeat write fails.
    $stdinProbe = [byte[]]::new(1)
    $stdinRead = $stdinStream.ReadAsync($stdinProbe, 0, 1)
    $lastHeartbeat = [DateTime]::UtcNow
    while (-not $stdinRead.IsCompleted) {
        $eventRecord = Wait-Event -Timeout 1
        if ($null -ne $eventRecord) {
            $eventPath = $eventRecord.SourceEventArgs.FullPath
            Write-Frame (@{ type = 'event'; watchID = $watchID; path = [string]$eventPath } | ConvertTo-Json -Compress)
            Remove-Event -EventIdentifier $eventRecord.EventIdentifier -ErrorAction SilentlyContinue
        }
        if (([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 10) {
            Write-Frame (@{ type = 'heartbeat' } | ConvertTo-Json -Compress)
            $lastHeartbeat = [DateTime]::UtcNow
        }
    }
    """#
}
