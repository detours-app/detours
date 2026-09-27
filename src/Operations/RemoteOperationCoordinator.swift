import Foundation
import os.log
import RemoteOperationSupport

actor RemoteOperationCoordinator {
    struct Endpoint: Sendable {
        let session: RemoteHostSession
        let request: @Sendable (OperationRequest) async throws -> OperationReply
        let upload: @Sendable (URL, OperationRequestIdentity) async throws -> OperationReceipt
    }

    enum Work: Sendable {
        case execute
        case copy
        case upload(URL)
        case uploadTree(URL)
        case archive(password: String?)
    }

    struct PlannedItem: Sendable {
        let intent: OperationIntent
        let hostID: UUID
        let work: Work
        var preflightFailure: RemoteOperationStore.PreflightFailure?
        var requiresVerified: [OperationItemID] = []
    }

    private let store: RemoteOperationStore
    private let resolve: @Sendable (UUID) async throws -> Endpoint
    private var active: Set<OperationItemID> = []
    var activeBatches: Set<UUID> = []
    private static let logger = Logger(subsystem: "com.detours", category: "remote-operation")

    init(store: RemoteOperationStore, resolve: @escaping @Sendable (UUID) async throws -> Endpoint) {
        self.store = store
        self.resolve = resolve
    }

    func create() throws -> UUID {
        let operation = UUID()
        try save(.init(operation: operation))
        return operation
    }

    func snapshot(_ operation: UUID) throws -> RemoteOperationStore.Snapshot { try store.load(operation) }

    private var resultObserver: (@Sendable (RemoteOperationStore.Snapshot) -> Void)?

    func reversedItemIDs() throws -> Set<OperationItemID> {
        Set(try store.all().flatMap(\.items).filter { $0.outcome == .committed }.compactMap { $0.result.intent.reverses })
    }

    func observeResults(_ observer: @escaping @Sendable (RemoteOperationStore.Snapshot) -> Void) {
        resultObserver = observer
    }

    @discardableResult
    private func save(_ snapshot: RemoteOperationStore.Snapshot) throws -> RemoteOperationStore.Snapshot {
        let saved = try store.save(snapshot)
        resultObserver?(saved)
        return saved
    }

    func recordHostNames(_ names: [UUID: String], operation: UUID) throws {
        var snapshot = try store.load(operation)
        guard snapshot.hostNames != names else { return }
        snapshot.hostNames = names
        try save(snapshot)
    }

    func recordSelections(_ selections: [OperationIntent], operation: UUID) throws {
        var snapshot = try store.load(operation)
        let recorded = selections.isEmpty ? nil : selections
        if snapshot.selections == recorded { return }
        guard snapshot.selections == nil, snapshot.items.allSatisfy({ $0.sent.isEmpty }) else {
            throw OperationContractError.intentMismatch
        }
        snapshot.selections = recorded
        try save(snapshot)
    }

    func lookup(_ path: OperationLocation.Path, hostID: UUID, proveContent: Bool = false) async throws
        -> (location: OperationLocation, result: OperationLookup<OperationObservation>) {
        let endpoint = try await resolve(hostID)
        let lifetime = try await endpoint.session.acquireLifetime(.reader)
        defer { lifetime.release() }
        let ready = try await endpoint.session.ensureReady()
        let location = OperationLocation(account: ready.handshake.account, path: path)
        let reply = try await endpoint.request(proveContent ? .sourceProof(location) : .lookup(location))
        switch reply {
        case .lookup(let result): return (location, result)
        case .incompatible(let error): throw error
        default: throw OperationContractError.invalidReceipt
        }
    }

    func sourceManifest(_ path: OperationLocation.Path, hostID: UUID) async throws
        -> (location: OperationLocation, result: OperationLookup<OperationManifest>) {
        let endpoint = try await resolve(hostID)
        let lifetime = try await endpoint.session.acquireLifetime(.reader)
        defer { lifetime.release() }
        let ready = try await endpoint.session.ensureReady()
        let location = OperationLocation(account: ready.handshake.account, path: path)
        switch try await endpoint.request(.sourceManifest(location)) {
        case .manifest(let result): return (location, result)
        case .incompatible(let error): throw error
        default: throw OperationContractError.invalidReceipt
        }
    }

    func archiveLayout(_ path: OperationLocation.Path, hostID: UUID, format: String, password: String?) async throws
        -> (location: OperationLocation, result: OperationLookup<OperationArchiveLayout>) {
        let endpoint = try await resolve(hostID)
        let lifetime = try await endpoint.session.acquireLifetime(.reader)
        defer { lifetime.release() }
        let ready = try await endpoint.session.ensureReady()
        let location = OperationLocation(account: ready.handshake.account, path: path)
        switch try await endpoint.request(.archiveLayout(location: location, format: format, password: password)) {
        case .archiveLayout(let result): return (location, result)
        case .archivePasswordRequired: throw FileOperationError.archivePasswordRequired
        case .incompatible(let error): throw error
        default: throw OperationContractError.invalidReceipt
        }
    }

    func recordPlannedItem(_ planned: PlannedItem) async throws {
        if let existing = try itemIfPresent(planned.intent.id) {
            guard existing.hostID == planned.hostID, existing.result.intent == planned.intent,
                  (existing.requiresVerified ?? []) == planned.requiresVerified,
                  existing.preflightFailure == planned.preflightFailure else {
                throw OperationContractError.intentMismatch
            }
            return
        }
        let endpoint = try await resolve(planned.hostID)
        let lifetime = try await endpoint.session.acquireLifetime(.operation)
        defer { lifetime.release() }
        let ready = try await endpoint.session.ensureReady()
        try Task.checkCancellation()
        var snapshot = try store.load(planned.intent.id.operation)
        try snapshot.record.accept(planned.intent)
        let result = OperationOutcomeReducer(intent: planned.intent, account: ready.handshake.account,
                                             epoch: ready.handshake.epoch,
                                             intentDigest: try OperationContentProof.data(planned.intent.canonicalData()).sha256)
        snapshot.items.append(.init(hostID: planned.hostID, result: result, preflightFailure: planned.preflightFailure,
            requiresVerified: planned.requiresVerified.isEmpty ? nil : planned.requiresVerified))
        try save(snapshot)
    }

    func restore() throws -> [RemoteOperationStore.Snapshot] {
        try store.all().map { saved in
            var next = saved
            for index in next.items.indices where next.items[index].pending != nil {
                next.items[index].result.loseContact()
            }
            return next == saved ? saved : try save(next)
        }
    }

    func perform(_ intent: OperationIntent, hostID: UUID, work: Work) async throws -> OperationOutcomeReducer {
        guard !active.contains(intent.id) else { throw OperationJournalError.busy }
        active.insert(intent.id)
        defer { active.remove(intent.id) }
        if let previous = try itemIfPresent(intent.id) {
            guard previous.hostID == hostID, previous.result.intent == intent else {
                throw OperationContractError.intentMismatch
            }
            let saved = try snapshot(intent.id.operation)
            guard (previous.requiresVerified ?? []).allSatisfy({ dependency in
                guard let item = saved.items.first(where: { $0.identity.id == dependency }),
                      item.outcome == .committed, let receipt = item.result.receipt else { return false }
                return receipt.contentVerified && !receipt.effects.isEmpty && !item.result.contactLost
            }) else { return previous.result }
            if previous.pending != nil {
                var snapshot = try store.load(intent.id.operation)
                let position = try index(intent.id, in: snapshot)
                snapshot.items[position].result.loseContact()
                try save(snapshot)
                return snapshot.items[position].result
            }
            if !previous.sent.isEmpty || previous.result.cancellationRequested || intent.conflict == .skip || previous.preflightFailure != nil {
                return previous.result
            }
        }
        return try await withTaskCancellationHandler {
            let endpoint = try await resolve(hostID)
            let lifetime = try await endpoint.session.acquireLifetime(.operation)
            defer { lifetime.release() }
            let ready = try await endpoint.session.ensureReady()
            try Task.checkCancellation()
            var snapshot = try store.load(intent.id.operation)
            try snapshot.record.accept(intent)
            let result = OperationOutcomeReducer(intent: intent, account: ready.handshake.account,
                                                 epoch: ready.handshake.epoch,
                                                 intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            if let previous = snapshot.items.first(where: { $0.identity.id == intent.id }) {
                try ready.handshake.validate(expectedAccount: previous.result.account, expectedEpoch: previous.result.epoch)
            } else {
                snapshot.items.append(.init(hostID: hostID, result: result))
                try save(snapshot)
            }
            if intent.conflict == .skip { return result }
            do {
                try await submit(intent.id, step: .accept, endpoint: endpoint) { identity in
                    try await endpoint.request(.accept(identity: identity, intent: intent))
                }
                if try item(intent.id).result.receipt?.phase == .terminal { return try item(intent.id).result }
                switch work {
                case .execute:
                    try await submit(intent.id, step: .execute, endpoint: endpoint) { identity in
                        try await endpoint.request(.execute(identity))
                    }
                case .copy, .upload, .uploadTree, .archive:
                    try await prepare(intent.id, work: work, endpoint: endpoint)
                    if case .uploadTree = work, try item(intent.id).result.receipt?.phase == .payloadReceived {
                        try await submit(intent.id, step: .expandUpload, endpoint: endpoint) { identity in
                            try await endpoint.request(.prepareImportedTree(identity))
                        }
                    }
                    let prepared = try item(intent.id)
                    if prepared.result.receipt?.phase == .readyToCommit {
                        try await submit(intent.id, step: .commit, endpoint: endpoint) { identity in
                            try await endpoint.request(.commit(identity))
                        }
                    }
                }
                return try item(intent.id).result
            } catch {
                var failed = try store.load(intent.id.operation)
                let index = try index(intent.id, in: failed)
                if Task.isCancelled {
                    failed.record.requestCancellation()
                    for position in failed.items.indices { failed.items[position].result.requestCancellation() }
                }
                if failed.items[index].pending != nil || !(error is CancellationError || error as? OperationContractError == .cancelled) {
                    failed.items[index].result.loseContact()
                }
                try save(failed)
                if failed.items[index].sent.isEmpty { throw error }
                return failed.items[index].result
            }
        } onCancel: {
            Task {
                do {
                    try await self.cancel(intent.id.operation)
                } catch {
                    Self.logger.error("Remote cancellation could not be confirmed; operation records retain the unresolved result.")
                }
            }
        }
    }

    func checkResult(_ id: OperationItemID) async throws -> OperationOutcomeReducer {
        let saved = try item(id)
        guard !saved.sent.isEmpty else { return saved.result }
        do {
            let endpoint = try await resolve(saved.hostID)
            let lifetime = try await endpoint.session.acquireLifetime(.operation)
            defer { lifetime.release() }
            try await validate(saved, endpoint: endpoint)
            let reply = try await endpoint.request(.status(saved.identity))
            try consume(reply, id: id, completed: nil)
        } catch {
            var snapshot = try store.load(id.operation)
            snapshot.items[try index(id, in: snapshot)].result.loseContact()
            try save(snapshot)
            throw error
        }
        return try item(id).result
    }

    func cancel(_ operation: UUID) async throws {
        var snapshot = try store.load(operation)
        snapshot.record.requestCancellation()
        for index in snapshot.items.indices { snapshot.items[index].result.requestCancellation() }
        snapshot = try save(snapshot)
        var failure: Error?
        for item in snapshot.items where !item.sent.isEmpty {
            do {
                let endpoint = try await resolve(item.hostID)
                let lifetime = try await endpoint.session.acquireLifetime(.operation)
                defer { lifetime.release() }
                try await validate(item, endpoint: endpoint)
                guard case .cancellationRecorded(let identity) = try await endpoint.request(.cancel(item.identity)),
                      identity == item.identity else { throw OperationContractError.invalidReceipt }
            } catch {
                failure = error
                var current = try store.load(operation)
                current.items[try index(item.identity.id, in: current)].result.loseContact()
                try save(current)
            }
        }
        if let failure { throw failure }
    }

    func takeUndoRegistration(_ id: OperationItemID) throws -> OperationReceipt? {
        var snapshot = try store.load(id.operation)
        let receipt = snapshot.items[try index(id, in: snapshot)].result.takeUndoRegistration()
        if receipt != nil { try save(snapshot) }
        return receipt
    }

    private func prepare(_ id: OperationItemID, work: Work, endpoint: Endpoint) async throws {
        try await submit(id, step: .prepare, endpoint: endpoint) { identity in
            switch work {
            case .copy: return try await endpoint.request(.prepareCopy(identity))
            case .upload(let source), .uploadTree(let source): return .receipt(try await endpoint.upload(source, identity))
            case .archive(let password): return try await endpoint.request(.prepareArchive(identity: identity, password: password))
            case .execute: throw OperationContractError.invalidReceipt
            }
        }
    }

    private func submit(_ id: OperationItemID, step: RemoteOperationStore.Step, endpoint: Endpoint,
                        send: @Sendable (OperationRequestIdentity) async throws -> OperationReply) async throws {
        try await validate(item(id), endpoint: endpoint)
        try Task.checkCancellation()
        var snapshot = try store.load(id.operation)
        let position = try index(id, in: snapshot)
        var item = snapshot.items[position]
        guard !snapshot.record.cancellationRequested else { throw OperationContractError.cancelled }
        guard !item.sent.contains(step), item.pending == nil, !item.result.contactLost,
              step == .accept || item.hostAccepted else { throw OperationContractError.invalidReceipt }
        guard item.result.receipt?.phase != .terminal else { throw OperationContractError.invalidReceipt }
        if step == .commit {
            guard item.result.receipt?.phase == .readyToCommit else { throw OperationContractError.invalidReceipt }
        }
        if !item.result.submitted { try item.result.markSubmitted() }
        item.sent.insert(step)
        item.pending = step
        snapshot.items[position] = item
        try save(snapshot)
        // Persist before the transport can write its first byte. Any failed exchange remains non-replayable.
        let reply = try await send(item.identity)
        try consume(reply, id: id, completed: step)
    }

    private func consume(_ reply: OperationReply, id: OperationItemID, completed: RemoteOperationStore.Step?) throws {
        var snapshot = try store.load(id.operation)
        let position = try index(id, in: snapshot)
        var item = snapshot.items[position]
        switch reply {
        case .accepted(let host), .status(let host):
            guard host.schemaVersion == 1, host.id == id, host.account == item.result.account,
                  host.epoch == item.result.epoch, host.intentDigest == item.result.intentDigest,
                  host.intent == nil || host.intent == item.result.intent else {
                throw OperationContractError.invalidReceipt
            }
            if completed != nil && completed != .accept { throw OperationContractError.invalidReceipt }
            item.hostAccepted = true
            if let receipt = host.receipt { try item.result.receive(receipt) }
        case .receipt(let receipt):
            guard completed != .accept else { throw OperationContractError.invalidReceipt }
            try item.result.receive(receipt)
        case .incompatible(let error): throw error
        default: throw OperationContractError.invalidReceipt
        }
        if completed != nil || [.committed, .partial, .failedUnchanged].contains(item.result.outcome) {
            item.pending = nil
        } else if item.pending != nil {
            item.result.loseContact()
        }
        snapshot.items[position] = item
        try save(snapshot)
    }

    private func validate(_ item: RemoteOperationStore.Item, endpoint: Endpoint) async throws {
        let ready = try await endpoint.session.ensureReady()
        try ready.handshake.validate(expectedAccount: item.result.account, expectedEpoch: item.result.epoch)
    }

    private func itemIfPresent(_ id: OperationItemID) throws -> RemoteOperationStore.Item? {
        try store.load(id.operation).items.first { $0.identity.id == id }
    }

    private func item(_ id: OperationItemID) throws -> RemoteOperationStore.Item {
        guard let item = try itemIfPresent(id) else { throw RemoteOperationStore.StoreError.missing }
        return item
    }

    private func index(_ id: OperationItemID, in snapshot: RemoteOperationStore.Snapshot) throws -> Int {
        guard let index = snapshot.items.firstIndex(where: { $0.identity.id == id }) else {
            throw RemoteOperationStore.StoreError.missing
        }
        return index
    }
}
