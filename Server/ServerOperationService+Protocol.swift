import Foundation
import RemoteOperationSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension ServerOperationService {
    static func live(homeDirectory: URL? = nil) async throws -> ServerOperationService {
        let hostIdentity: String
        #if canImport(Darwin)
        var hostUUID = UUID().uuid
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&hostUUID, &timeout) == 0 else { throw OperationFilesystemError.system(errno) }
        hostIdentity = UUID(uuid: hostUUID).uuidString.lowercased()
        #else
        let machineID = try String(contentsOfFile: "/etc/machine-id", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard machineID.count == 32, machineID.allSatisfy({ $0.isHexDigit }) else { throw OperationFilesystemError.unsupported }
        hostIdentity = machineID.lowercased()
        #endif
        let account = OperationAccount(hostIdentity: hostIdentity, accountIdentity: "uid:\(getuid())")
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".detours-server/operations")
        return try await ServerOperationService(root: root, account: account, homeDirectory: home)
    }

    func reply(to request: OperationRequest) async throws -> OperationReply {
        do {
            return try await dispatch(request)
        } catch OperationContractError.epochMismatch {
            return .incompatible(.epochChanged)
        } catch OperationContractError.identityMismatch {
            return .incompatible(.accountMismatch)
        }
    }

    private func dispatch(_ request: OperationRequest) async throws -> OperationReply {
        switch request {
        case .handshake(let version, let schema, let required):
            try journal.validateEpoch()
            guard version == OperationHandshake.protocolVersion else {
                return .incompatible(.protocolVersion(expected: OperationHandshake.protocolVersion, actual: version))
            }
            guard schema == OperationHandshake.journalSchema else {
                return .incompatible(.journalSchema(expected: OperationHandshake.journalSchema, actual: schema))
            }
            let capabilities = Set(OperationCapability.allCases)
            let missing = required.subtracting(capabilities)
            guard missing.isEmpty else { return .incompatible(.missingCapabilities(missing)) }
            return .handshake(OperationHandshake(version: version, schemaVersion: schema, capabilities: capabilities,
                                                account: journal.account, epoch: journal.epoch))
        case .lookup(let location), .sourceProof(let location):
            try journal.validateEpoch()
            guard location.account == journal.account else { return .incompatible(.accountMismatch) }
            do {
                let resolved = try resolve(location)
                if case .sourceProof = request {
                    return .lookup(.found(try resolved.directory.proveObject(resolved.name) { _ in try Task.checkCancellation() }))
                }
                return .lookup(try resolved.directory.lookup(resolved.name))
            } catch OperationFilesystemError.system(let code) {
                switch code {
                case ENOENT: return .lookup(.missing)
                case EACCES, EPERM: return .lookup(.denied)
                case ENOTCONN: return .lookup(.disconnected)
                default: throw OperationFilesystemError.system(code)
                }
            } catch OperationFilesystemError.unsupported { return .lookup(.unsupported) }
        case .sourceManifest(let location):
            try journal.validateEpoch()
            guard location.account == journal.account else { return .incompatible(.accountMismatch) }
            do {
                let resolved = try resolve(location)
                return .manifest(.found(try resolved.directory.manifest(resolved.name) { _ in try Task.checkCancellation() }))
            } catch OperationFilesystemError.system(let code) {
                switch code {
                case ENOENT: return .manifest(.missing)
                case EACCES, EPERM: return .manifest(.denied)
                case ENOTCONN: return .manifest(.disconnected)
                default: throw OperationFilesystemError.system(code)
                }
            } catch OperationFilesystemError.unsupported { return .manifest(.unsupported) }
        case .archiveLayout(let location, let format, let password):
            return try archiveLayout(location, format: format, password: password)
        case .accept(let identity, let intent):
            return .accepted(try await accept(identity, intent: intent))
        case .prepareUpload(let identity, let contents):
            return .receipt(try await prepareUpload(identity, contents: contents))
        case .prepareCopy(let identity):
            return .receipt(try await prepareCopy(identity))
        case .prepareImportedTree(let identity):
            return .receipt(try await prepareImportedTree(identity))
        case .prepareArchive(let identity, let password):
            return .receipt(try await prepareArchive(identity, password: password))
        case .commit(let identity):
            return .receipt(try await commit(identity))
        case .execute(let identity):
            return .receipt(try await execute(identity))
        case .status(let identity):
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: .status(try self.status(identity)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        case .cancel(let identity):
            try cancel(identity)
            return .cancellationRecorded(identity)
        case .acknowledge(let identity, let retainingUndo):
            try await acknowledge(identity, retainingUndo: retainingUndo)
            return .acknowledged(identity)
        }
    }
}

// RPC dispatch runs on a blocking worker queue, outside the Swift executor.
final class ServerOperationReplyBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<OperationReply, Error>?

    static func reply(to request: OperationRequest, service: ServerOperationService?,
                      homeDirectory: URL? = nil) throws -> OperationReply {
        try perform {
            let active: ServerOperationService
            if let service { active = service } else { active = try await ServerOperationService.live(homeDirectory: homeDirectory) }
            return try await active.reply(to: request)
        }
    }

    static func stream(_ identity: OperationRequestIdentity, input: FileHandle,
                       service: ServerOperationService?) throws -> OperationReply {
        try perform {
            let active: ServerOperationService
            if let service { active = service } else { active = try await ServerOperationService.live() }
            return .receipt(try await active.prepareStream(identity, input: input))
        }
    }

    private static func perform(_ work: @escaping @Sendable () async throws -> OperationReply) throws -> OperationReply {
        let bridge = ServerOperationReplyBridge()
        let completed = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                bridge.store(.success(try await work()))
            } catch { bridge.store(.failure(error)) }
            completed.signal()
        }
        completed.wait()
        return try bridge.take().get()
    }

    private func store(_ value: Result<OperationReply, Error>) {
        lock.lock()
        defer { lock.unlock() }
        result = value
    }

    private func take() throws -> Result<OperationReply, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw OperationContractError.invalidReceipt }
        return result
    }
}
