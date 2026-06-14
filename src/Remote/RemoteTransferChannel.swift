import Foundation

enum RemoteTransferError: Error, Equatable {
    case byteCountMismatch(expected: Int64, actual: Int64)
    case invalidHandshake
    case processFailed(String)
}

enum RemoteTransferDirection: UInt8, Equatable, Sendable {
    case upload = 1
    case download = 2
}

enum RemoteTransferRoute: Equatable, Sendable {
    case rpc
    case transferChannel
}

struct RemoteTransferHandshake: Equatable, Sendable {
    let direction: RemoteTransferDirection
    let source: RemotePath
    let destination: RemotePath
    let byteCount: Int64

    func binaryEncoded() -> Data {
        var writer = RPCBinaryWriter()
        writer.writeUInt8(direction.rawValue)
        writer.writeData(source.bytes)
        writer.writeData(destination.bytes)
        writer.writeInt64(byteCount)
        return writer.data
    }

    init(direction: RemoteTransferDirection, source: RemotePath, destination: RemotePath, byteCount: Int64) {
        self.direction = direction
        self.source = source
        self.destination = destination
        self.byteCount = byteCount
    }

    init(binaryEncoded data: Data) throws {
        var reader = RPCBinaryReader(data: data)
        let directionByte = try reader.readUInt8()
        guard let direction = RemoteTransferDirection(rawValue: directionByte) else {
            throw RemoteTransferError.invalidHandshake
        }

        self.direction = direction
        self.source = RemotePath(bytes: try reader.readData())
        self.destination = RemotePath(bytes: try reader.readData())
        self.byteCount = try reader.readInt64()
        try reader.requireComplete()
    }
}

actor RemoteTransferChannel {
    static let rpcThresholdBytes: Int64 = 1_048_576

    private let sshTarget: String
    private let remoteCommand: String
    private let controlDirectory: URL
    private let hostTrust: SSHHostTrust
    private let processFactory: @Sendable () -> Process

    init(
        sshTarget: String,
        remoteCommand: String = "~/.detours-server/detours-server",
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust(),
        processFactory: @escaping @Sendable () -> Process = { Process() }
    ) {
        self.sshTarget = sshTarget
        self.remoteCommand = remoteCommand
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.processFactory = processFactory
    }

    static func route(forByteCount byteCount: Int64) -> RemoteTransferRoute {
        byteCount > rpcThresholdBytes ? .transferChannel : .rpc
    }

    func makeHandshake(
        direction: RemoteTransferDirection,
        source: RemotePath,
        destination: RemotePath,
        byteCount: Int64
    ) -> RemoteTransferHandshake {
        RemoteTransferHandshake(
            direction: direction,
            source: source,
            destination: destination,
            byteCount: byteCount
        )
    }

    func startTransferProcess() throws -> Process {
        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        try hostTrust.prepareKnownHostsFile()
        process.arguments = sshArguments()
        try process.run()
        return process
    }

    func download(source: RemotePath, expectedByteCount: Int64, to destination: URL) async throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = try configuredTransferProcess(stdin: stdin, stdout: stdout, stderr: stderr)
        try process.run()

        let handshake = makeHandshake(
            direction: .download,
            source: source,
            destination: RemotePath(destination.path),
            byteCount: expectedByteCount
        )
        stdin.fileHandleForWriting.write(try RPCStreamHandler.encodeFrame(handshake.binaryEncoded()))
        try stdin.fileHandleForWriting.close()

        let partial = Self.partialURL(for: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)

        var written: Int64 = 0
        do {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let output = stdout.fileHandleForReading
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }

            while written < expectedByteCount {
                let remaining = min(64 * 1024, Int(expectedByteCount - written))
                let chunk = output.readData(ofLength: remaining)
                guard !chunk.isEmpty else { break }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }

            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw RemoteTransferError.processFailed(Self.stderrText(from: stderr))
            }
            guard written == expectedByteCount else {
                throw RemoteTransferError.byteCountMismatch(expected: expectedByteCount, actual: written)
            }

            try Self.movePartial(partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    func upload(source localURL: URL, destination: RemotePath, byteCount: Int64) async throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = try configuredTransferProcess(stdin: stdin, stdout: stdout, stderr: stderr)
        try process.run()

        let handshake = makeHandshake(
            direction: .upload,
            source: RemotePath(localURL.path),
            destination: destination,
            byteCount: byteCount
        )
        let input = stdin.fileHandleForWriting
        input.write(try RPCStreamHandler.encodeFrame(handshake.binaryEncoded()))

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { break }
            input.write(chunk)
        }
        try input.close()

        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RemoteTransferError.processFailed(Self.stderrText(from: stderr))
        }
    }

    func receiveDownloadForTesting(
        chunks: [Data],
        expectedByteCount: Int64,
        destination: URL,
        cancelAfterBytes: Int64? = nil
    ) async throws {
        let partial = Self.partialURL(for: destination)
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var written: Int64 = 0

        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }

            for chunk in chunks {
                if let cancelAfterBytes, written >= cancelAfterBytes {
                    throw CancellationError()
                }

                let remainingBeforeCancel = cancelAfterBytes.map { max(0, $0 - written) }
                if let remainingBeforeCancel, remainingBeforeCancel < Int64(chunk.count) {
                    let prefix = chunk.prefix(Int(remainingBeforeCancel))
                    try handle.write(contentsOf: prefix)
                    written += Int64(prefix.count)
                    throw CancellationError()
                }

                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }

            guard written == expectedByteCount else {
                throw RemoteTransferError.byteCountMismatch(expected: expectedByteCount, actual: written)
            }

            try Self.movePartial(partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".detours-partial")
    }

    #if DEBUG
    func sshArgumentsForTesting() -> [String] {
        sshArguments()
    }
    #endif

    private func configuredTransferProcess(stdin: Pipe, stdout: Pipe, stderr: Pipe) throws -> Process {
        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        try hostTrust.prepareKnownHostsFile()
        process.arguments = sshArguments()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        return process
    }

    private func sshArguments() -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
        ] + hostTrust.sshArguments + [
            sshTarget,
            remoteCommand,
            "--transfer",
        ]
    }

    private static func movePartial(_ partial: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private static func stderrText(from pipe: Pipe) -> String {
        String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
