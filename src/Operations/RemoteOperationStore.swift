import Darwin
import Foundation
import RemoteOperationSupport

/// Client records contain intent and evidence, never payloads, passwords or transport commands.
final class RemoteOperationStore: @unchecked Sendable {
    enum Step: String, Codable, Hashable, Sendable {
        case accept, prepare, expandUpload, commit, execute
    }

    enum PreflightFailure: String, Codable, Sendable {
        case sourceMissing, denied, disconnected, unsupported, linkLoop, linkTargetMissing, recoveryChanged
    }

    struct Item: Codable, Equatable, Sendable {
        let hostID: UUID
        var result: OperationOutcomeReducer
        var sent: Set<Step> = []
        var pending: Step?
        var hostAccepted = false
        var preflightFailure: PreflightFailure?
        var requiresVerified: [OperationItemID]?

        var outcome: OperationOutcome {
            if let preflightFailure { return preflightFailure == .disconnected ? .notStarted : .failedUnchanged }
            return result.outcome
        }

        var identity: OperationRequestIdentity {
            OperationRequestIdentity(id: result.intent.id, account: result.account,
                                     epoch: result.epoch, intentDigest: result.intentDigest)
        }
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let schemaVersion: Int
        var revision: UInt64
        var record: OperationRecord
        var items: [Item]
        var selections: [OperationIntent]?
        var hostNames: [UUID: String]?

        init(operation: UUID) {
            schemaVersion = 1
            revision = 0
            record = OperationRecord(operation: operation)
            items = []
        }
    }

    enum StoreError: Error, Equatable {
        case missing, staleRevision, unsafeRecord, busy
    }

    private let root: URL
    private let directory: OperationDirectory
    private let descriptor: Int32
    private let mutex = NSLock()

    convenience init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true)
        try self.init(root: support.appendingPathComponent("Detours/RemoteOperations", isDirectory: true))
    }

    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = try OperationDirectory(path: Data(root.path.utf8))
        try directory.requirePrivate()
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw OperationJournalError.system(errno) }
        self.root = root
        self.directory = directory
        self.descriptor = descriptor
    }

    deinit { _ = close(descriptor) }

    func load(_ operation: UUID) throws -> Snapshot {
        try locked {
            guard let snapshot = try read(operation) else { throw StoreError.missing }
            return snapshot
        }
    }

    func all() throws -> [Snapshot] {
        try locked {
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".json") }
                .sorted().map { name in
                    guard let operation = UUID(uuidString: String(name.dropLast(5))),
                          let snapshot = try read(operation) else { throw StoreError.unsafeRecord }
                    return snapshot
                }
        }
    }

    @discardableResult
    func save(_ proposed: Snapshot) throws -> Snapshot {
        try locked {
            try validate(proposed)
            let previous = try read(proposed.record.operation)
            guard proposed.revision == (previous?.revision ?? 0),
                  proposed.revision < UInt64.max else { throw StoreError.staleRevision }
            if let previous { try validateTransition(from: previous, to: proposed) }
            var saved = proposed
            saved.revision += 1
            let data = try JSONEncoder().encode(saved)
            let temporary = UUID().uuidString.lowercased() + ".snapshot"
            let allocated = try directory.createExclusiveFile(Data(temporary.utf8))
            do {
                try allocated.handle.write(contentsOf: data)
                try allocated.handle.synchronize()
                try allocated.handle.close()
                try directory.requirePrivate()
                guard renameat(descriptor, temporary, descriptor, filename(saved.record.operation)) == 0 else {
                    throw OperationJournalError.system(errno)
                }
                try directory.synchronize()
            } catch {
                // Only this invocation's exclusively allocated snapshot is eligible for cleanup.
                if case .found = try directory.lookup(Data(temporary.utf8)) {
                    try directory.removeOwnedFile(Data(temporary.utf8), identity: allocated.identity)
                }
                throw error
            }
            return saved
        }
    }

    private func locked<Value>(_ body: () throws -> Value) throws -> Value {
        try mutex.withLock {
            try directory.requirePrivate()
            let lock = openat(descriptor, "store.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard lock >= 0 else { throw OperationJournalError.system(errno) }
            defer { _ = close(lock) }
            try requirePrivateFile(lock)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }
            defer { _ = flock(lock, LOCK_UN) }
            return try body()
        }
    }

    private func read(_ operation: UUID) throws -> Snapshot? {
        let file = openat(descriptor, filename(operation), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw OperationJournalError.system(errno)
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        try requirePrivateFile(file)
        guard let data = try handle.readToEnd() else { throw StoreError.unsafeRecord }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        try validate(snapshot)
        guard snapshot.record.operation == operation, snapshot.revision > 0 else { throw StoreError.unsafeRecord }
        return snapshot
    }

    private func validate(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == 1, snapshot.record.schemaVersion == 1 else {
            throw OperationContractError.incompatibleSchema
        }
        let intents = snapshot.record.intents
        guard intents == snapshot.items.map({ $0.result.intent }),
              Set(intents.map(\.id)).count == intents.count,
              intents.allSatisfy({ $0.id.operation == snapshot.record.operation }) else {
            throw StoreError.unsafeRecord
        }
        for item in snapshot.items {
            let dependencies = item.requiresVerified ?? []
            guard item.pending.map({ item.sent.contains($0) }) ?? true,
                  Set(dependencies).count == dependencies.count,
                  dependencies.allSatisfy({ dependency in
                      guard let earlier = intents.firstIndex(where: { $0.id == dependency }),
                            let current = intents.firstIndex(where: { $0.id == item.identity.id }) else { return false }
                      return earlier < current
                  }),
                  !item.hostAccepted || item.sent.contains(.accept),
                  item.preflightFailure == nil || (item.sent.isEmpty && !item.result.submitted && item.result.receipt == nil),
                  !snapshot.record.cancellationRequested || item.result.cancellationRequested else {
                throw StoreError.unsafeRecord
            }
        }
        if let selections = snapshot.selections {
            let identifiers = Set(intents.map(\.id))
            guard Set(selections.map(\.id)).count == selections.count,
                  selections.allSatisfy({ selection in
                      selection.id.operation == snapshot.record.operation && !identifiers.contains(selection.id)
                          && selection.children.allSatisfy({ identifiers.contains($0) })
                          && Set(selection.children).count == selection.children.count
                  }) else { throw StoreError.unsafeRecord }
        }
    }

    private func validateTransition(from previous: Snapshot, to next: Snapshot) throws {
        guard next.items.count >= previous.items.count,
              previous.selections == nil || previous.selections == next.selections,
              !previous.items.contains(where: { !$0.sent.isEmpty }) || previous.selections == next.selections,
              !previous.record.cancellationRequested || next.record.cancellationRequested else {
            throw StoreError.unsafeRecord
        }
        for (old, new) in zip(previous.items, next.items) {
            guard old.hostID == new.hostID, old.result.intent == new.result.intent,
                  old.preflightFailure == new.preflightFailure,
                  old.requiresVerified == new.requiresVerified,
                  old.identity == new.identity, old.sent.isSubset(of: new.sent),
                  !old.hostAccepted || new.hostAccepted,
                  !old.result.submitted || new.result.submitted,
                  !old.result.undoRegistered || new.result.undoRegistered,
                  !old.result.cancellationRequested || new.result.cancellationRequested else {
                throw OperationContractError.intentMismatch
            }
            if let receipt = old.result.receipt {
                guard let updated = new.result.receipt, updated.revision >= receipt.revision else {
                    throw OperationContractError.conflictingRevision
                }
                var checked = old.result
                try checked.receive(updated)
            }
        }
    }

    private func requirePrivateFile(_ file: Int32) throws {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw OperationJournalError.system(errno) }
        guard info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw StoreError.unsafeRecord }
    }

    private func filename(_ operation: UUID) -> String { operation.uuidString.lowercased() + ".json" }
}
