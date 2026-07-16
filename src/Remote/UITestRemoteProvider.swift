import CryptoKit
import Foundation

enum UITestRemoteCallPhase: String, Codable, Sendable {
    case started
    case completed
    case failed
}

/// A mutable, local-directory-backed remote host used exclusively by UI tests.
///
/// Every translated path is confined to `base`, including paths that pass through symlinks. The
/// provider also exposes a file-backed control surface under the test root so UI tests can hold an
/// exact listing call, fail the next named operation, and inspect provider call history without
/// relying on sleeps.
actor UITestRemoteProvider: FileProvider {
    struct CallRecord: Codable, Sendable {
        let sequence: UInt64
        let hostID: UUID
        let operation: String
        let sources: [String]
        let destination: String?
        let changedParents: [String]
        let phase: UITestRemoteCallPhase
        let detail: String?
    }

    private struct FailureControl: Codable {
        let id: String
        let operation: String
        let message: String?
    }

    private struct ListingGateNotice: Codable {
        let sequence: UInt64
        let hostID: UUID
        let path: String
        let callNumber: Int
    }

    private struct ListingGateRule: Hashable {
        let path: String
        let callNumber: Int

        init?(_ value: String) {
            let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
            guard let path = parts.first, !path.isEmpty else { return nil }
            let callNumber = parts.count == 2 ? Int(parts[1]) ?? 1 : 1
            guard callNumber > 0 else { return nil }
            self.path = Self.normalizedPath(path)
            self.callNumber = callNumber
        }

        private static func normalizedPath(_ path: String) -> String {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "/" : "/" + trimmed
        }
    }

    private struct WatchRegistration {
        let token: FileProviderWatch
        let callback: @Sendable (Location) -> Void
    }

    let hostID: UUID
    private let base: URL
    private let resolvedBase: URL
    private let listingGateRules: Set<ListingGateRule>
    private var launchFailureQueue: [String]
    private var listCallCounts: [String: Int] = [:]
    private var nextSequence: UInt64 = 0
    private var watches: [FileProviderWatch: WatchRegistration] = [:]

    private static let historyFileName = ".detours-remote-provider-history.json"
    private static let failureFileName = ".detours-remote-provider-failure.json"
    private static let failureAcknowledgementFileName = ".detours-remote-provider-failure-ack.json"
    private static let trashDirectoryName = ".detours-remote-provider-trash"
    private static let gateWaitingPrefix = ".detours-remote-list-gate-"

    init(hostID: UUID, base: URL) {
        self.hostID = hostID
        self.base = base.standardizedFileURL
        self.resolvedBase = base.standardizedFileURL.resolvingSymlinksInPath()

        let environmentRules = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_REMOTE_LISTING_GATES"]?
            .split(separator: ",")
            .compactMap { ListingGateRule(String($0)) } ?? []
        let argumentRules = ProcessInfo.processInfo.arguments.compactMap { argument -> ListingGateRule? in
            let prefix = "--detours-ui-test-remote-listing-gate="
            guard argument.hasPrefix(prefix) else { return nil }
            return ListingGateRule(String(argument.dropFirst(prefix.count)))
        }
        self.listingGateRules = Set(environmentRules + argumentRules)

        let environmentFailures = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_REMOTE_FAIL_NEXT"]?
            .split(separator: ",")
            .map(String.init) ?? []
        let argumentFailures = ProcessInfo.processInfo.arguments.compactMap { argument -> String? in
            let prefix = "--detours-ui-test-remote-fail-next="
            guard argument.hasPrefix(prefix) else { return nil }
            return String(argument.dropFirst(prefix.count))
        }
        self.launchFailureQueue = environmentFailures + argumentFailures
    }

    // MARK: - Listing and metadata

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        let path = try remotePath(from: location)
        let sequence = beginCall(operation: "list", sources: [path], destination: nil)
        do {
            try failIfRequested(operation: "list")
            try await holdListingIfRequested(path: path, sequence: sequence)
            let directory = try confinedURL(for: location, mustExist: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Self.resourceKeys,
                options: []
            )
            let entries = try urls
                .filter { !Self.isControlFile($0.lastPathComponent) }
                .filter { showHidden || !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map(makeEntry)
            completeCall(sequence: sequence, operation: "list", sources: [path])
            return entries
        } catch {
            failCall(sequence: sequence, operation: "list", sources: [path], error: error)
            throw error
        }
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        let path = try remotePath(from: location)
        let sequence = beginCall(operation: "stat", sources: [path], destination: nil)
        do {
            try failIfRequested(operation: "stat")
            let entry = try makeEntry(try confinedURL(for: location, mustExist: true))
            completeCall(sequence: sequence, operation: "stat", sources: [path])
            return entry
        } catch {
            failCall(sequence: sequence, operation: "stat", sources: [path], error: error)
            throw error
        }
    }

    // MARK: - Mutations

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        try await transfer(sources, to: destination, operation: "copy", removesSources: false)
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        try await transfer(sources, to: destination, operation: "move", removesSources: true)
    }

    private func transfer(
        _ sources: [Location],
        to destination: Location,
        operation: String,
        removesSources: Bool
    ) async throws -> [Location] {
        let sourcePaths = try sources.map(remotePath(from:))
        let destinationPath = try remotePath(from: destination)
        let sequence = beginCall(operation: operation, sources: sourcePaths, destination: destinationPath)
        do {
            try failIfRequested(operation: operation)
            let destinationURL = try confinedURL(for: destination, mustExist: true)
            try requireDirectory(destinationURL)
            var results: [Location] = []
            var changedParents: Set<Location> = [destination]
            for source in sources {
                let sourceURL = try confinedURL(for: source, mustExist: true)
                let targetURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
                try requireConfined(targetURL, mustExist: false)
                if removesSources {
                    try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    changedParents.insert(source.deletingLastPathComponent())
                } else {
                    try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                }
                results.append(remoteLocation(for: targetURL))
            }
            notifyChangedParents(changedParents)
            completeCall(
                sequence: sequence,
                operation: operation,
                sources: sourcePaths,
                destination: destinationPath,
                changedParents: changedParents
            )
            return results
        } catch {
            failCall(
                sequence: sequence,
                operation: operation,
                sources: sourcePaths,
                destination: destinationPath,
                error: error
            )
            throw error
        }
    }

    func delete(_ items: [Location]) async throws {
        let paths = try items.map(remotePath(from:))
        let sequence = beginCall(operation: "delete", sources: paths, destination: nil)
        do {
            try failIfRequested(operation: "delete")
            let changedParents = Set(items.map { $0.deletingLastPathComponent() })
            for item in items {
                try FileManager.default.removeItem(at: confinedURL(for: item, mustExist: true))
            }
            notifyChangedParents(changedParents)
            completeCall(sequence: sequence, operation: "delete", sources: paths, changedParents: changedParents)
        } catch {
            failCall(sequence: sequence, operation: "delete", sources: paths, error: error)
            throw error
        }
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        let paths = try items.map(remotePath(from:))
        let sequence = beginCall(operation: "trash", sources: paths, destination: nil)
        do {
            try failIfRequested(operation: "trash")
            let trashRoot = base.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            var results: [TrashedItem] = []
            let changedParents = Set(items.map { $0.deletingLastPathComponent() })
            for item in items {
                let source = try confinedURL(for: item, mustExist: true)
                let tokenDirectory = trashRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tokenDirectory, withIntermediateDirectories: false)
                let trashedURL = tokenDirectory.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: trashedURL)
                results.append(TrashedItem(originalLocation: item, trashLocation: remoteLocation(for: trashedURL)))
            }
            notifyChangedParents(changedParents)
            completeCall(sequence: sequence, operation: "trash", sources: paths, changedParents: changedParents)
            return results
        } catch {
            failCall(sequence: sequence, operation: "trash", sources: paths, error: error)
            throw error
        }
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        let paths = try items.map { try remotePath(from: $0.trashLocation) }
        let sequence = beginCall(operation: "restoreFromTrash", sources: paths, destination: nil)
        do {
            try failIfRequested(operation: "restoreFromTrash")
            var restored: [Location] = []
            var changedParents: Set<Location> = []
            for item in items {
                let source = try confinedURL(for: item.trashLocation, mustExist: true)
                let destination = try confinedURL(for: item.originalLocation, mustExist: false)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: source, to: destination)
                restored.append(item.originalLocation)
                changedParents.insert(item.originalLocation.deletingLastPathComponent())
            }
            notifyChangedParents(changedParents)
            completeCall(
                sequence: sequence,
                operation: "restoreFromTrash",
                sources: paths,
                changedParents: changedParents
            )
            return restored
        } catch {
            failCall(sequence: sequence, operation: "restoreFromTrash", sources: paths, error: error)
            throw error
        }
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        let sourcePath = try remotePath(from: item)
        let sequence = beginCall(operation: "rename", sources: [sourcePath], destination: newName)
        do {
            try failIfRequested(operation: "rename")
            guard !newName.isEmpty, newName != ".", newName != "..", !newName.contains("/") else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let source = try confinedURL(for: item, mustExist: true)
            let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
            try requireConfined(destination, mustExist: false)
            try FileManager.default.moveItem(at: source, to: destination)
            let changedParents: Set<Location> = [item.deletingLastPathComponent()]
            notifyChangedParents(changedParents)
            completeCall(
                sequence: sequence,
                operation: "rename",
                sources: [sourcePath],
                destination: newName,
                changedParents: changedParents
            )
            return remoteLocation(for: destination)
        } catch {
            failCall(
                sequence: sequence,
                operation: "rename",
                sources: [sourcePath],
                destination: newName,
                error: error
            )
            throw error
        }
    }

    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {
        let path = try remotePath(from: location)
        let sequence = beginCall(operation: "createDirectory", sources: [], destination: path)
        do {
            try failIfRequested(operation: "createDirectory")
            let destination = try confinedURL(for: location, mustExist: false)
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: withIntermediateDirectories
            )
            let changedParents: Set<Location> = [location.deletingLastPathComponent()]
            notifyChangedParents(changedParents)
            completeCall(
                sequence: sequence,
                operation: "createDirectory",
                sources: [],
                destination: path,
                changedParents: changedParents
            )
        } catch {
            failCall(
                sequence: sequence,
                operation: "createDirectory",
                sources: [],
                destination: path,
                error: error
            )
            throw error
        }
    }

    // MARK: - Watches and transfers

    func watch(
        _ location: Location,
        onChange: @escaping @Sendable (Location) -> Void
    ) async throws -> FileProviderWatch {
        _ = try confinedURL(for: location, mustExist: true)
        let token = FileProviderWatch(id: UUID(), location: location)
        watches[token] = WatchRegistration(token: token, callback: onChange)
        let sequence = beginCall(operation: "watch", sources: [location.path], destination: nil)
        completeCall(sequence: sequence, operation: "watch", sources: [location.path])
        return token
    }

    func unwatch(_ watch: FileProviderWatch) async {
        watches.removeValue(forKey: watch)
        let sequence = beginCall(operation: "unwatch", sources: [watch.location.path], destination: nil)
        completeCall(sequence: sequence, operation: "unwatch", sources: [watch.location.path])
    }

    func download(_ location: Location, to localURL: URL) async throws {
        let path = try remotePath(from: location)
        let sequence = beginCall(operation: "download", sources: [path], destination: localURL.path)
        do {
            try failIfRequested(operation: "download")
            try FileManager.default.copyItem(at: confinedURL(for: location, mustExist: true), to: localURL)
            completeCall(sequence: sequence, operation: "download", sources: [path], destination: localURL.path)
        } catch {
            failCall(
                sequence: sequence,
                operation: "download",
                sources: [path],
                destination: localURL.path,
                error: error
            )
            throw error
        }
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        let path = try remotePath(from: location)
        let sequence = beginCall(operation: "upload", sources: [localURL.path], destination: path)
        do {
            try failIfRequested(operation: "upload")
            let destination = try confinedURL(for: location, mustExist: false)
            try FileManager.default.copyItem(at: localURL, to: destination)
            let changedParents: Set<Location> = [location.deletingLastPathComponent()]
            notifyChangedParents(changedParents)
            completeCall(
                sequence: sequence,
                operation: "upload",
                sources: [localURL.path],
                destination: path,
                changedParents: changedParents
            )
        } catch {
            failCall(
                sequence: sequence,
                operation: "upload",
                sources: [localURL.path],
                destination: path,
                error: error
            )
            throw error
        }
    }

    func version(of location: Location) async throws -> RemoteFileVersion {
        let url = try confinedURL(for: location, mustExist: true)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return RemoteFileVersion(
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            modificationDate: values.contentModificationDate ?? .distantPast
        )
    }

    func folderSize(for location: Location) async throws -> Int64 {
        try Self.calculateFolderSize(at: confinedURL(for: location, mustExist: true))
    }

    func readSymlink(_ location: Location) async throws -> Location {
        let url = try confinedURL(for: location, mustExist: true)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let resolved = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appendingPathComponent(destination)
        try requireConfined(resolved, mustExist: true)
        return remoteLocation(for: resolved.resolvingSymlinksInPath())
    }

    func openForQuickLook(_ location: Location) async throws -> URL {
        try confinedURL(for: location, mustExist: true)
    }

    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }

    func archiveCreate(
        _ items: [Location],
        format: ArchiveFormat,
        archiveName: String,
        password: String?
    ) async throws -> Location {
        throw FileProviderError.unsupportedOperation("archiveCreate")
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        throw FileProviderError.unsupportedOperation("archiveExtract")
    }

    nonisolated func find(query: String, cap: Int) -> AsyncThrowingStream<[FoundItem], Error> {
        let hostID = self.hostID
        let base = self.base
        return AsyncThrowingStream { continuation in
            let needle = query.lowercased()
            guard !needle.isEmpty else {
                continuation.finish()
                return
            }
            var items: [FoundItem] = []
            let basePath = base.standardizedFileURL.path
            if let enumerator = FileManager.default.enumerator(atPath: base.path) {
                for case let relative as String in enumerator {
                    if items.count >= cap { break }
                    if relative.split(separator: "/").contains(where: { Self.isControlFile(String($0)) }) {
                        continue
                    }
                    let name = (relative as NSString).lastPathComponent
                    guard name.lowercased().contains(needle) else { continue }
                    let fullURL = base.appendingPathComponent(relative)
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(
                        atPath: fullURL.path,
                        isDirectory: &isDirectory
                    )
                    guard exists else { continue }
                    let suffix = String(fullURL.path.dropFirst(basePath.count))
                    let path = suffix.isEmpty ? "/" : suffix
                    items.append(FoundItem(
                        location: .remote(hostID: hostID, path: path),
                        isDirectory: isDirectory.boolValue
                    ))
                }
            }
            if !items.isEmpty { continuation.yield(items) }
            continuation.finish()
        }
    }

    // MARK: - Deterministic controls

    private func holdListingIfRequested(path: String, sequence: UInt64) async throws {
        let normalizedPath = Self.normalizedRemotePath(path)
        let callNumber = listCallCounts[normalizedPath, default: 0] + 1
        listCallCounts[normalizedPath] = callNumber
        guard listingGateRules.contains(ListingGateRule("\(normalizedPath)#\(callNumber)")!) else { return }

        let waitingURL = gateURL(sequence: sequence, suffix: "waiting.json")
        let releaseURL = gateURL(sequence: sequence, suffix: "release")
        let notice = ListingGateNotice(
            sequence: sequence,
            hostID: hostID,
            path: normalizedPath,
            callNumber: callNumber
        )
        try JSONEncoder().encode(notice).write(to: waitingURL, options: .atomic)
        while !FileManager.default.fileExists(atPath: releaseURL.path) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try? FileManager.default.removeItem(at: releaseURL)
        try? FileManager.default.removeItem(at: waitingURL)
    }

    private func failIfRequested(operation: String) throws {
        if launchFailureQueue.first == operation {
            launchFailureQueue.removeFirst()
            throw FileProviderError.unsupportedOperation("UI-test forced \(operation) failure")
        }

        let controlURL = base.appendingPathComponent(Self.failureFileName)
        guard let data = try? Data(contentsOf: controlURL),
              let control = try? JSONDecoder().decode(FailureControl.self, from: data),
              control.operation == operation else {
            return
        }
        try FileManager.default.removeItem(at: controlURL)
        let acknowledgementURL = base.appendingPathComponent(Self.failureAcknowledgementFileName)
        try JSONEncoder().encode(control).write(to: acknowledgementURL, options: .atomic)
        throw FileProviderError.unsupportedOperation(
            control.message ?? "UI-test forced \(operation) failure"
        )
    }

    // MARK: - Confinement and records

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isAliasFileKey,
        .isSymbolicLinkKey,
        .isReadableKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    private func makeEntry(_ localURL: URL) throws -> LoadedFileEntry {
        try requireConfined(localURL, mustExist: true)
        let values = try localURL.resourceValues(forKeys: Set(Self.resourceKeys))
        let path = remotePath(forLocal: localURL)
        return LoadedFileEntry(
            location: .remote(hostID: hostID, path: path),
            url: URL(fileURLWithPath: path),
            name: localURL.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            isAliasFile: values.isAliasFile ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            isReadable: values.isReadable ?? true,
            isHidden: values.isHidden ?? localURL.lastPathComponent.hasPrefix("."),
            fileSize: values.isDirectory == true ? nil : values.fileSize.map(Int64.init),
            contentModificationDate: values.contentModificationDate ?? Date()
        )
    }

    private func remotePath(from location: Location) throws -> String {
        guard case .remote(let requestedHostID, let path) = location,
              requestedHostID == hostID else {
            throw FileProviderError.unsupportedRemote(location)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw FileProviderError.unsupportedOperation("UI-test remote path escapes its root")
        }
        return Self.normalizedRemotePath(path)
    }

    private func confinedURL(for location: Location, mustExist: Bool) throws -> URL {
        let path = try remotePath(from: location)
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = trimmed.isEmpty ? base : base.appendingPathComponent(trimmed)
        try requireConfined(url, mustExist: mustExist)
        return url
    }

    private func requireConfined(_ url: URL, mustExist: Bool) throws {
        let standardized = url.standardizedFileURL
        let parent = mustExist ? standardized : standardized.deletingLastPathComponent()
        let resolved = parent.resolvingSymlinksInPath()
        let basePath = resolvedBase.path
        let resolvedPath = resolved.path
        guard resolvedPath == basePath || resolvedPath.hasPrefix(basePath + "/") else {
            throw FileProviderError.unsupportedOperation("UI-test remote path escapes its root")
        }
        if mustExist, !FileManager.default.fileExists(atPath: standardized.path) {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileWriteFileExists)
        }
    }

    private func remoteLocation(for localURL: URL) -> Location {
        .remote(hostID: hostID, path: remotePath(forLocal: localURL))
    }

    private func remotePath(forLocal localURL: URL) -> String {
        let path = localURL.standardizedFileURL.path
        let suffix = String(path.dropFirst(base.path.count))
        return suffix.isEmpty ? "/" : Self.normalizedRemotePath(suffix)
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/" + trimmed
    }

    private static func isControlFile(_ name: String) -> Bool {
        name.hasPrefix(".detours-")
    }

    private static func calculateFolderSize(at directory: URL) throws -> Int64 {
        var total: Int64 = 0
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        )
        for child in children where !isControlFile(child.lastPathComponent) {
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
            )
            if values.isDirectory == true {
                total += try calculateFolderSize(at: child)
            } else if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func notifyChangedParents(_ parents: Set<Location>) {
        for parent in parents.sorted(by: { $0.path < $1.path }) {
            for registration in watches.values where registration.token.location == parent {
                registration.callback(parent)
            }
        }
    }

    @discardableResult
    private func beginCall(operation: String, sources: [String], destination: String?) -> UInt64 {
        nextSequence &+= 1
        appendRecord(CallRecord(
            sequence: nextSequence,
            hostID: hostID,
            operation: operation,
            sources: sources,
            destination: destination,
            changedParents: [],
            phase: .started,
            detail: nil
        ))
        return nextSequence
    }

    private func completeCall(
        sequence: UInt64,
        operation: String,
        sources: [String],
        destination: String? = nil,
        changedParents: Set<Location> = []
    ) {
        appendRecord(CallRecord(
            sequence: sequence,
            hostID: hostID,
            operation: operation,
            sources: sources,
            destination: destination,
            changedParents: changedParents.map(\.path).sorted(),
            phase: .completed,
            detail: nil
        ))
    }

    private func failCall(
        sequence: UInt64,
        operation: String,
        sources: [String],
        destination: String? = nil,
        error: any Error
    ) {
        appendRecord(CallRecord(
            sequence: sequence,
            hostID: hostID,
            operation: operation,
            sources: sources,
            destination: destination,
            changedParents: [],
            phase: .failed,
            detail: error.localizedDescription
        ))
    }

    private func appendRecord(_ record: CallRecord) {
        let url = base.appendingPathComponent(Self.historyFileName)
        var records: [CallRecord] = []
        if let data = try? Data(contentsOf: url) {
            records = (try? JSONDecoder().decode([CallRecord].self, from: data)) ?? []
        }
        records.append(record)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func gateURL(sequence: UInt64, suffix: String) -> URL {
        base.appendingPathComponent("\(Self.gateWaitingPrefix)\(sequence).\(suffix)")
    }
}
