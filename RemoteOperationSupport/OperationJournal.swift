import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum OperationJournalError: Error, Equatable {
    case system(Int32)
    case unsafeObject
    case missingRecord
    case busy
    case recoveryOutstanding
}

public final class OperationJournal: Sendable {
    public struct Snapshot: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let epoch: UUID
        public let account: OperationAccount
        public let id: OperationItemID
        public let intentDigest: String
        public let revision: UInt64
        public let intent: OperationIntent?
        public let receipt: OperationReceipt?
        public let acknowledged: Bool
        public let workspace: OperationWorkspace.Record?
        public let sourceManifest: OperationManifest?
        public let payloadManifest: OperationManifest?
    }

    public final class Ownership: Sendable {
        fileprivate let descriptor: Int32
        fileprivate let journal: OperationJournal
        fileprivate let id: OperationItemID?

        fileprivate init(descriptor: Int32, journal: OperationJournal, id: OperationItemID?) {
            self.descriptor = descriptor
            self.journal = journal
            self.id = id
        }

        deinit {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
    }

    private struct EpochRecord: Codable {
        let schemaVersion: Int
        let epoch: UUID
        let account: OperationAccount
    }

    public let account: OperationAccount
    private let directory: Int32
    private let root: URL
    public let epoch: UUID

    public init(root: URL, account: OperationAccount) async throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw OperationJournalError.system(errno) }
        do {
            try Self.requirePrivate(descriptor, directory: true)
            let lock = try await Self.acquire(directory: descriptor, name: "epoch.lock")
            defer {
                _ = flock(lock, LOCK_UN)
                _ = close(lock)
            }
            let epochRecord: EpochRecord
            if let data = try Self.readFile(directory: descriptor, name: "epoch.json") {
                epochRecord = try JSONDecoder().decode(EpochRecord.self, from: data)
                guard epochRecord.schemaVersion == 1 else { throw OperationContractError.incompatibleSchema }
                guard epochRecord.account == account else { throw OperationContractError.identityMismatch }
            } else {
                epochRecord = EpochRecord(schemaVersion: 1, epoch: UUID(), account: account)
                try Self.write(epochRecord, directory: descriptor, name: "epoch.json")
            }
            self.directory = descriptor
            self.root = root
            self.account = account
            self.epoch = epochRecord.epoch
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    deinit { _ = close(directory) }

    public func acquireItem(_ id: OperationItemID) async throws -> Ownership {
        try validateEpoch()
        let descriptor = try await Self.acquire(directory: directory, name: name(id) + ".lock")
        return Ownership(descriptor: descriptor, journal: self, id: id)
    }

    public func acquireCommit() async throws -> Ownership {
        try validateEpoch()
        let descriptor = try await Self.acquire(directory: directory, name: "commit.lock")
        return Ownership(descriptor: descriptor, journal: self, id: nil)
    }

    public func tryAcquireItem(_ id: OperationItemID) throws -> Ownership? {
        try validateEpoch()
        let descriptor = openat(directory, name(id) + ".lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw OperationJournalError.system(errno) }
        do {
            try Self.requirePrivate(descriptor, directory: false)
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return Ownership(descriptor: descriptor, journal: self, id: id)
            }
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                _ = close(descriptor)
                return nil
            }
            throw OperationJournalError.system(code)
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func acquire(directory: Int32, name: String) async throws -> Int32 {
        let descriptor = openat(directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw OperationJournalError.system(errno) }
        do {
            try Self.requirePrivate(descriptor, directory: false)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while true {
                try Task.checkCancellation()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    return descriptor
                }
                guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                    throw OperationJournalError.system(errno)
                }
                guard clock.now < deadline else { throw OperationJournalError.busy }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    public func read(_ id: OperationItemID) throws -> Snapshot {
        try validateEpoch()
        guard let data = try readFile(name(id) + ".json") else { throw OperationJournalError.missingRecord }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw OperationContractError.incompatibleSchema }
        guard snapshot.account == account, snapshot.id == id else { throw OperationContractError.identityMismatch }
        guard snapshot.epoch == epoch else { throw OperationContractError.epochMismatch }
        return snapshot
    }

    public func accept(_ intent: OperationIntent, digest: String, ownership: Ownership) throws -> Snapshot {
        try validateEpoch()
        try requireOwnership(ownership, id: intent.id)
        if let data = try readFile(name(intent.id) + ".json") {
            let existing = try JSONDecoder().decode(Snapshot.self, from: data)
            guard existing.intentDigest == digest, existing.intent == nil || existing.intent == intent else {
                throw OperationContractError.intentMismatch
            }
            return try read(intent.id)
        }
        guard try !cancellationRequested(intent.id) else { throw OperationContractError.cancelled }
        let snapshot = Snapshot(
            schemaVersion: 1, epoch: epoch, account: account, id: intent.id,
            intentDigest: digest, revision: 1, intent: intent, receipt: nil, acknowledged: false, workspace: nil, sourceManifest: nil, payloadManifest: nil
        )
        try write(snapshot, name: name(intent.id) + ".json")
        return snapshot
    }

    public func record(_ receipt: OperationReceipt, ownership: Ownership) throws {
        try requireOwnership(ownership, id: receipt.id)
        let previous = try read(receipt.id)
        guard !previous.acknowledged, let intent = previous.intent else {
            throw OperationContractError.invalidReceipt
        }
        var reducer = OperationOutcomeReducer(intent: intent, account: account, epoch: epoch, intentDigest: previous.intentDigest)
        if let oldReceipt = previous.receipt { try reducer.receive(oldReceipt) }
        try reducer.receive(receipt)
        if reducer.receipt == previous.receipt { return }
        let snapshot = Snapshot(
            schemaVersion: 1, epoch: epoch, account: account, id: receipt.id,
            intentDigest: previous.intentDigest, revision: previous.revision + 1,
            intent: intent, receipt: receipt, acknowledged: false, workspace: previous.workspace,
            sourceManifest: previous.sourceManifest, payloadManifest: previous.payloadManifest
        )
        try write(snapshot, name: name(receipt.id) + ".json")
    }

    public func acknowledge(_ id: OperationItemID, retainingUndo: Bool, ownership: Ownership) throws {
        try requireOwnership(ownership, id: id)
        let previous = try read(id)
        if previous.acknowledged { return }
        guard !retainingUndo, let receipt = previous.receipt, canCompact(receipt) else {
            throw OperationJournalError.recoveryOutstanding
        }
        let tombstone = Snapshot(
            schemaVersion: 1, epoch: epoch, account: account, id: id,
            intentDigest: previous.intentDigest, revision: previous.revision + 1,
            intent: nil, receipt: receipt, acknowledged: true, workspace: nil, sourceManifest: nil, payloadManifest: nil
        )
        try write(tombstone, name: name(id) + ".json")
    }

    public func requestCancellation(_ id: OperationItemID) throws {
        try write(id, name: name(id) + ".cancel")
    }

    public func recordWorkspace(_ workspace: OperationWorkspace.Record, ownership: Ownership) throws {
        try requireOwnership(ownership, id: workspace.id)
        let previous = try read(workspace.id)
        guard !previous.acknowledged else { throw OperationContractError.invalidReceipt }
        if let saved = previous.workspace {
            guard saved.root == workspace.root, workspace.objects.starts(with: saved.objects) else {
                throw OperationContractError.identityMismatch
            }
        }
        try write(Snapshot(
            schemaVersion: 1, epoch: epoch, account: account, id: workspace.id, intentDigest: previous.intentDigest,
            revision: previous.revision + 1, intent: previous.intent, receipt: previous.receipt,
            acknowledged: false, workspace: workspace,
            sourceManifest: previous.sourceManifest, payloadManifest: previous.payloadManifest
        ), name: name(workspace.id) + ".json")
    }

    public func recordManifests(_ id: OperationItemID, source: OperationManifest,
                                payload: OperationManifest?, ownership: Ownership) throws {
        try requireOwnership(ownership, id: id)
        let previous = try read(id)
        guard !previous.acknowledged, previous.receipt == nil || previous.receipt?.phase == .preparing,
              previous.sourceManifest == nil || previous.sourceManifest == source,
              previous.payloadManifest == nil || previous.payloadManifest == payload else {
            throw OperationContractError.identityMismatch
        }
        if previous.sourceManifest == source, previous.payloadManifest == payload { return }
        try write(Snapshot(
            schemaVersion: 1, epoch: epoch, account: account, id: id, intentDigest: previous.intentDigest,
            revision: previous.revision + 1, intent: previous.intent, receipt: previous.receipt,
            acknowledged: false, workspace: previous.workspace, sourceManifest: source, payloadManifest: payload
        ), name: name(id) + ".json")
    }

    public func cancellationRequested(_ id: OperationItemID) throws -> Bool {
        try validateEpoch()
        guard let data = try readFile(name(id) + ".cancel") else { return false }
        guard try JSONDecoder().decode(OperationItemID.self, from: data) == id else {
            throw OperationContractError.identityMismatch
        }
        return true
    }

    private func canCompact(_ receipt: OperationReceipt) -> Bool {
        receipt.phase == .terminal && [.committed, .failedUnchanged].contains(receipt.outcome)
            && receipt.recovery.isEmpty && receipt.children.allSatisfy(canCompact)
    }

    private func requireOwnership(_ ownership: Ownership, id: OperationItemID) throws {
        guard ownership.journal === self, ownership.id == id else { throw OperationContractError.identityMismatch }
    }

    private func name(_ id: OperationItemID) -> String {
        id.operation.uuidString.lowercased() + "-" + id.item.uuidString.lowercased()
    }

    private func readFile(_ name: String) throws -> Data? {
        try Self.readFile(directory: directory, name: name)
    }

    private static func readFile(directory: Int32, name: String) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw OperationJournalError.system(errno)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try Self.requirePrivate(descriptor, directory: false)
        return try handle.readToEnd() ?? Data()
    }

    private func write<Value: Encodable>(_ value: Value, name: String) throws {
        try validateEpoch()
        try Self.write(value, directory: directory, name: name)
    }

    public func validateEpoch() throws {
        let currentDirectory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentDirectory >= 0 else { throw OperationContractError.epochMismatch }
        defer { _ = close(currentDirectory) }
        var opened = stat()
        var currentInfo = stat()
        guard fstat(directory, &opened) == 0, fstat(currentDirectory, &currentInfo) == 0 else {
            throw OperationJournalError.system(errno)
        }
        guard opened.st_dev == currentInfo.st_dev, opened.st_ino == currentInfo.st_ino else {
            throw OperationContractError.epochMismatch
        }
        try Self.requirePrivate(currentDirectory, directory: true)
        guard let data = try readFile("epoch.json") else { throw OperationContractError.epochMismatch }
        let current = try JSONDecoder().decode(EpochRecord.self, from: data)
        guard current.schemaVersion == 1 else { throw OperationContractError.incompatibleSchema }
        guard current.account == account else { throw OperationContractError.identityMismatch }
        guard current.epoch == epoch else { throw OperationContractError.epochMismatch }
    }

    private static func write<Value: Encodable>(_ value: Value, directory: Int32, name: String) throws {
        let data = try JSONEncoder().encode(value)
        let temporary = UUID().uuidString.lowercased() + ".snapshot"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw OperationJournalError.system(errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw OperationJournalError.system(errno) }
        guard renameat(directory, temporary, directory, name) == 0 else { throw OperationJournalError.system(errno) }
        guard fsync(directory) == 0 else { throw OperationJournalError.system(errno) }
    }

    private static func requirePrivate(_ descriptor: Int32, directory: Bool) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw OperationJournalError.system(errno) }
        let expected = directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        guard info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == expected,
              info.st_mode & mode_t(0o077) == 0 else { throw OperationJournalError.unsafeObject }
    }
}
