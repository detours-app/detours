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
        case .responseIDMismatch(let expected, let actual):
            return "PowerShell response id \(actual) did not match request id \(expected)."
        case .remoteError(let message), .invalidResponse(let message), .processFailed(let message),
             .timeout(let message):
            return message
        case .unexpectedEOF:
            return "The Windows PowerShell channel closed before sending a complete response."
        }
    }
}

protocol PowerShellChannelTransport: Sendable {
    func start(dispatcherBase64: String) async throws
    func sendFrame(_ frame: Data) async throws
    func readFrame() async throws -> Data
    func stop() async
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
    private var nextRequestID: UInt64 = 1
    private var isStarted = false
    private var activePaneCount = 0

    init(
        sshTarget: String,
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust()
    ) {
        transport = PowerShellProcessTransport(
            sshTarget: sshTarget,
            controlDirectory: controlDirectory,
            hostTrust: hostTrust,
            executionMode: .oneShot
        )
    }

    init(transport: any PowerShellChannelTransport) {
        self.transport = transport
    }

    func run(_ script: PowerShellScript, operation: String) async throws -> Data {
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

        do {
            let responsePayload = try await transport.readFrame()
            let response = try JSONDecoder.detoursWindows.decode(Response.self, from: responsePayload)
            guard response.id == requestID else {
                throw PowerShellChannelError.responseIDMismatch(expected: requestID, actual: response.id)
            }
            guard response.ok else {
                throw PowerShellChannelError.remoteError(response.error ?? "PowerShell operation failed.")
            }
            return Data((response.resultJSON ?? "null").utf8)
        } catch {
            await restartAfterProtocolFailure()
            throw error
        }
    }

    func setActivePaneCount(_ count: Int) async {
        activePaneCount = max(0, count)
        if activePaneCount == 0 {
            Task { await stopIfIdle() }
        }
    }

    func forceReconnect() async throws {
        await transport.stop()
        isStarted = false
        try await startIfNeeded()
    }

    func disconnect() async {
        await transport.stop()
        isStarted = false
        activePaneCount = 0
    }

    #if DEBUG
    func isStartedForTesting() -> Bool {
        isStarted
    }
    #endif

    private func startIfNeeded() async throws {
        guard !isStarted else { return }
        try await transport.start(dispatcherBase64: Self.dispatcherBase64)
        isStarted = true
    }

    private func restartAfterProtocolFailure() async {
        await transport.stop()
        isStarted = false
        if activePaneCount > 0 {
            try? await startIfNeeded()
        }
    }

    private func stopIfIdle() async {
        guard activePaneCount == 0 else { return }
        await transport.stop()
        isStarted = false
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
            $resultJson = $result | ConvertTo-Json -Compress -Depth 8
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

final class PowerShellProcessTransport: PowerShellChannelTransport, @unchecked Sendable {
    enum ExecutionMode: Equatable {
        case persistent
        case oneShot
    }

    private static let readTimeoutMilliseconds: Int32 = 30_000

    private let sshTarget: String
    private let controlDirectory: URL
    private let hostTrust: SSHHostTrust
    private let processFactory: @Sendable () -> Process
    private let executionMode: ExecutionMode
    private let stateLock = NSLock()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var dispatcherBase64: String?

    init(
        sshTarget: String,
        controlDirectory: URL,
        hostTrust: SSHHostTrust,
        executionMode: ExecutionMode = .persistent,
        processFactory: @escaping @Sendable () -> Process = { Process() }
    ) {
        self.sshTarget = sshTarget
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.executionMode = executionMode
        self.processFactory = processFactory
    }

    func start(dispatcherBase64: String) async throws {
        try hostTrust.prepareKnownHostsFile()
        self.dispatcherBase64 = dispatcherBase64
        guard executionMode == .persistent else { return }
        try startProcess(dispatcherBase64: dispatcherBase64)
    }

    private func startProcess(dispatcherBase64: String) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard process == nil else { return }
        let process = processFactory()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(dispatcherBase64: dispatcherBase64)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            ProcessRetirement.retireOnMain(process)
            throw error
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
    }

    func sendFrame(_ frame: Data) async throws {
        if executionMode == .oneShot {
            guard let dispatcherBase64 else {
                throw PowerShellChannelError.processFailed("PowerShell channel is not connected.")
            }
            try startProcess(dispatcherBase64: dispatcherBase64)
        }
        let (_, stdinPipe) = try processForWriting()
        stdinPipe.fileHandleForWriting.write(frame)
        if executionMode == .oneShot {
            stdinPipe.fileHandleForWriting.closeFile()
            clearStdinPipeIfCurrent(stdinPipe)
        }
    }

    func readFrame() async throws -> Data {
        let (runningProcess, stdoutPipe) = try processForReading()
        let output = stdoutPipe.fileHandleForReading
        defer {
            if executionMode == .oneShot {
                stopProcess()
            }
        }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try withExtendedLifetime((runningProcess, stdoutPipe)) {
                    let lengthData = try Self.readExact(4, from: output)
                    let length = Int(UInt32(bigEndianData: lengthData.prefix(4)))
                    return try Self.readExact(length, from: output)
                }
            }.value
        } catch {
            if executionMode == .persistent {
                stopProcess()
            }
            throw error
        }
    }

    func stop() async {
        stopProcess()
    }

    private func stopProcess() {
        stateLock.lock()
        let runningProcess = process
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stateLock.unlock()
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
            runningProcess?.waitUntilExit()
        }
        ProcessRetirement.retireOnMain(runningProcess)
    }

    private func processForWriting() throws -> (Process, Pipe) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runningProcess = process, runningProcess.isRunning, let stdinPipe else {
            throw PowerShellChannelError.processFailed("PowerShell channel is not connected.")
        }
        return (runningProcess, stdinPipe)
    }

    private func processForReading() throws -> (Process, Pipe) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runningProcess = process, let stdoutPipe else {
            throw PowerShellChannelError.processFailed("PowerShell channel is not connected.")
        }
        return (runningProcess, stdoutPipe)
    }

    private func clearStdinPipeIfCurrent(_ pipe: Pipe) {
        stateLock.lock()
        if stdinPipe === pipe {
            stdinPipe = nil
        }
        stateLock.unlock()
    }

    private func sshArguments(dispatcherBase64: String) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
        ] + hostTrust.sshArguments + [
            sshTarget,
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            dispatcherBase64,
        ]
    }

    private static func readExact(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        let fileDescriptor = handle.fileDescriptor
        while result.count < count {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, readTimeoutMilliseconds)
            if pollResult == 0 {
                throw PowerShellChannelError.timeout("Timed out waiting for Windows PowerShell response.")
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw PowerShellChannelError.processFailed(String(cString: strerror(errno)))
            }
            if descriptor.revents & Int16(POLLIN) == 0 {
                throw PowerShellChannelError.unexpectedEOF
            }

            let remaining = count - result.count
            var buffer = [UInt8](repeating: 0, count: remaining)
            let byteCount = Darwin.read(fileDescriptor, &buffer, remaining)
            if byteCount > 0 {
                result.append(buffer, count: byteCount)
            } else if byteCount == 0 {
                throw PowerShellChannelError.unexpectedEOF
            } else if errno != EINTR {
                throw PowerShellChannelError.processFailed(String(cString: strerror(errno)))
            }
        }
        return result
    }
}
