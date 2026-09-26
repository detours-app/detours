import Foundation
import RemoteOperationSupport

enum RemoteTransferError: LocalizedError, Equatable {
    case byteCountMismatch(expected: Int64, actual: Int64)
    case invalidHandshake
    case acceptedOperationRequired
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .byteCountMismatch(let expected, let actual):
            return "The transfer stopped after \(actual) of \(expected) bytes."
        case .acceptedOperationRequired:
            return "Remote changes require an accepted operation. Reconnect with a compatible Detours client."
        case .invalidHandshake:
            return "The remote host did not accept the transfer request."
        case .processFailed(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "The remote host closed the transfer connection."
                : "The remote host refused the transfer: \(trimmed)"
        }
    }
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
    private let session: RemoteHostSession?

    init(
        sshTarget: String,
        remoteCommand: String = "~/.detours-server/detours-server",
        controlDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/ssh", isDirectory: true),
        hostTrust: SSHHostTrust = SSHHostTrust(),
        session: RemoteHostSession? = nil,
        processFactory: @escaping @Sendable () -> Process = { Process() }
    ) {
        self.sshTarget = sshTarget
        self.remoteCommand = remoteCommand
        self.controlDirectory = controlDirectory
        self.hostTrust = hostTrust
        self.processFactory = processFactory
        self.session = session
        _ = BrokenPipe.ignored
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

    func download(source: RemotePath, expectedByteCount: Int64, to destination: URL) async throws {
        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments()
        let worker = RemoteProcessWorker(process: process)
        let hostTrust = self.hostTrust
        let handshake = makeHandshake(
            direction: .download, source: source,
            destination: RemotePath(destination.path), byteCount: expectedByteCount
        )
        let body: @Sendable (RemoteProcessWorker) throws -> Void = { worker in
            try hostTrust.prepareKnownHostsFile()
            try worker.start()
            try worker.write(RPCStreamHandler.encodeFrame(handshake.binaryEncoded()))
            worker.closeInput()
            try Self.receiveDownload(worker: worker, expectedByteCount: expectedByteCount, destination: destination)
        }
        if let session {
            try await session.performOwnedWorker(worker, kind: .reader, body: body)
        } else {
            try await worker.perform(body)
        }
    }

    private static func receiveDownload(worker: RemoteProcessWorker, expectedByteCount: Int64, destination: URL) throws {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".detours-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var written: Int64 = 0
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            while written < expectedByteCount {
                let remaining = Int(min(64 * 1024, expectedByteCount - written))
                let chunk = try worker.read(maximumBytes: remaining, timeout: .seconds(30))
                guard !chunk.isEmpty else { break }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
            let extra = try worker.read(maximumBytes: 1, timeout: .seconds(10))
            guard extra.isEmpty else {
                throw RemoteTransferError.byteCountMismatch(expected: expectedByteCount, actual: written + Int64(extra.count))
            }
            guard try worker.waitForExit() == 0 else {
                worker.finishDiagnostics()
                throw RemoteTransferError.processFailed(worker.diagnostics)
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
        throw RemoteTransferError.acceptedOperationRequired
    }

    func prepareAcceptedUpload(source: URL, identity: OperationRequestIdentity, rpcClient: any RemoteRPCClient) async throws -> OperationReceipt {
        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments()
        let worker = RemoteProcessWorker(process: process)
        let hostTrust = self.hostTrust
        let body: @Sendable () async throws -> OperationReceipt = {
            try hostTrust.prepareKnownHostsFile()
            return try await Self.performAcceptedUpload(source: source, identity: identity, rpcClient: rpcClient, worker: worker)
        }
        if let session { return try await session.withOwnedWorker(worker, kind: .operation, body: body) }
        return try await body()
    }

    static func performAcceptedUpload(source: URL, identity: OperationRequestIdentity,
                                      rpcClient: any RemoteRPCClient, worker: RemoteProcessWorker) async throws -> OperationReceipt {
        let progress = RemoteMeasuredProgress()
        let monitor = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    let chunks = try await rpcClient.send(.operation(.status(identity)))
                    guard chunks.count == 1, let data = chunks.first,
                          case .status(let snapshot) = try OperationReply.decode(data),
                          snapshot.id == identity.id, snapshot.account == identity.account,
                          snapshot.epoch == identity.epoch, snapshot.intentDigest == identity.intentDigest else {
                        throw RemoteFileProviderError.invalidResponse("Unverified upload progress")
                    }
                    if let measured = snapshot.receipt?.measuredBytes { progress.record(measured) }
                }
            } catch {
                if !Task.isCancelled { progress.fail(error); worker.requestStop() }
            }
        }
        defer { monitor.cancel() }
        do {
            try await worker.perform { try $0.start() }
            let response = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    try await worker.perform { worker in
                        let handshake = Data([3]) + (try OperationStreamHandshake(identity: identity).encoded())
                        try worker.write(RPCStreamHandler.encodeFrame(handshake))
                        let input = try FileHandle(forReadingFrom: source)
                        defer { try? input.close() }
                        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                            try worker.write(chunk, timeout: .seconds(30), progress: progress)
                        }
                        worker.closeInput()
                    }
                    return nil
                }
                group.addTask {
                    try await worker.perform { try $0.readFrame(progress: progress) }
                }
                var response: Data?
                for try await result in group { if let result { response = result } }
                guard let response else { throw RemoteTransferError.invalidHandshake }
                return response
            }
            let status = try await worker.perform { try $0.waitForExit() }
            guard status == 0 else {
                worker.finishDiagnostics()
                throw RemoteTransferError.processFailed(worker.diagnostics)
            }
            guard case .receipt(let receipt) = try OperationReply.decode(response),
                  receipt.id == identity.id, receipt.account == identity.account,
                  receipt.epoch == identity.epoch, receipt.intentDigest == identity.intentDigest else {
                throw RemoteTransferError.invalidHandshake
            }
            return receipt
        } catch {
            try Task.checkCancellation()
            try progress.check()
            throw error
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

}
