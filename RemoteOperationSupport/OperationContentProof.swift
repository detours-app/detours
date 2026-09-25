import Foundation
#if canImport(CryptoKit)
import CryptoKit
import Darwin
#else
import Glibc
#endif

public struct OperationContentProof: Codable, Equatable, Sendable {
    public let byteCount: UInt64
    public let sha256: String

    public init(byteCount: UInt64, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public static func read(_ handle: FileHandle, progress: (UInt64) throws -> Void) throws -> Self {
        try calculate(read: { try handle.read(upToCount: 64 * 1024) }, progress: progress)
    }

    public static func data(_ data: Data) throws -> Self {
        var offset = 0
        return try calculate(read: {
            guard offset < data.count else { return nil }
            let end = min(offset + 64 * 1024, data.count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }, progress: { _ in })
    }

    private static func calculate(read: () throws -> Data?, progress: (UInt64) throws -> Void) throws -> Self {
        #if canImport(CryptoKit)
        var digest = SHA256()
        var count: UInt64 = 0
        while let chunk = try read(), !chunk.isEmpty {
            digest.update(data: chunk)
            count += UInt64(chunk.count)
            try progress(count)
        }
        return Self(byteCount: count, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
        #else
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.arguments = []
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        var count: UInt64 = 0
        do {
            while let chunk = try read(), !chunk.isEmpty {
                try input.fileHandleForWriting.write(contentsOf: chunk)
                count += UInt64(chunk.count)
                try progress(count)
            }
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            throw error
        }
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0, result.count < 128,
              let text = String(data: result, encoding: .utf8),
              let digest = text.split(whereSeparator: \.isWhitespace).first, digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else { throw OperationFilesystemError.unsupported }
        return Self(byteCount: count, sha256: String(digest))
        #endif
    }
}

extension OperationDirectory {
    public func openFile(_ name: Data) throws -> FileHandle {
        try Self.validateName(name)
        let descriptor = try Self.withBytes(name) { openat(self.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { throw Self.systemError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.systemError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw OperationFilesystemError.unsupported }
        return handle
    }

    public func proveFile(_ name: Data, progress: (UInt64) throws -> Void) throws -> OperationObservation {
        let before = try observe(name)
        guard before.kind == .file else { throw OperationFilesystemError.unsupported }
        let handle = try openFile(name)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw Self.systemError() }
        guard Self.identity(info) == before.identity else { throw OperationFilesystemError.identityChanged }
        let proof = try OperationContentProof.read(handle, progress: progress)
        guard try observe(name) == before, proof.byteCount == before.byteCount else {
            throw OperationFilesystemError.identityChanged
        }
        return OperationObservation(identity: before.identity, kind: before.kind, version: before.version,
                                    byteCount: proof.byteCount, sha256: proof.sha256, linkTarget: nil,
                                    contentVersion: before.contentVersion)
    }
}
