import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func treeCopyManifest(_ location: OperationLocation, identity: OperationRequestIdentity,
                          ownership: OperationJournal.Ownership, measuredBefore: UInt64) async throws -> OperationManifest {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let source = try self.resolve(location)
                    let clock = ContinuousClock()
                    var reported = clock.now
                    let manifest = try source.directory.manifest(source.name) { measured in
                        guard try !self.journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
                        if clock.now - reported >= .seconds(5) {
                            try self.recordTreeProgress(identity, measured: measuredBefore + measured, ownership: ownership)
                            reported = clock.now
                        }
                    }
                    continuation.resume(returning: manifest)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func treeCopyFile(_ sourceEffect: OperationEffect, output: FileHandle,
                      identity: OperationRequestIdentity, ownership: OperationJournal.Ownership,
                      measuredBefore: UInt64) async throws {
        defer { try? output.close() }
        let source = try resolve(sourceEffect.location)
        let expected = sourceEffect.observation
        let handle = try source.directory.openObservedFile(source.name, expected: expected)
        defer {
            try? handle.close()
        }
        let input = ServerOperationInput.sourceFile(handle, source.directory, source.name, expected)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let clock = ContinuousClock()
                    var reported = clock.now
                    var received: UInt64 = 0
                    while true {
                        guard try !self.journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
                        let chunk = try input.next(offset: received, expected: expected.byteCount) {
                            try self.journal.cancellationRequested(identity.id)
                        }
                        if chunk.isEmpty { break }
                        try output.write(contentsOf: chunk)
                        received += UInt64(chunk.count)
                        if clock.now - reported >= .seconds(5) {
                            try self.recordTreeProgress(identity, measured: measuredBefore + received, ownership: ownership)
                            reported = clock.now
                        }
                    }
                    guard received == expected.byteCount else { throw OperationContractError.invalidReceipt }
                    try input.copyMetadata(to: output)
                    try output.synchronize()
                    try input.validateSource()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        try output.close()
        try handle.close()
    }

    func recordTreeProgress(_ identity: OperationRequestIdentity, measured: UInt64,
                            ownership: OperationJournal.Ownership) throws {
        let current = try journal.read(identity.id)
        try journal.record(OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: current.receipt?.phase ?? .preparing, outcome: .running,
            effects: current.receipt?.effects ?? [],
            sourceDisposition: current.receipt?.sourceDisposition ?? (current.intent?.action == .move ? .present : .notRequired),
            contentVerified: current.receipt?.contentVerified ?? false, preparedPayload: current.receipt?.preparedPayload,
            plannedPaths: current.receipt?.plannedPaths, measuredBytes: measured, recovery: current.receipt?.recovery ?? []
        ), ownership: ownership)
    }

    func treeMemberLocation(_ root: OperationLocation, relative: Data) throws -> OperationLocation {
        guard case .unix(let path) = root.path else { throw OperationFilesystemError.invalidPath }
        if relative.isEmpty { return root }
        return OperationLocation(account: root.account, path: .unix(path + Data([47]) + relative))
    }
}
