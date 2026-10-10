import DetoursProcess
import Foundation
import RemoteOperationSupport

#if DEBUG
enum RarExtractionStage: Sendable { case discovered, output, prepared, publishing, published }
#endif

extension FileOperationQueue {
    func performExtractRar(archive: URL, password: String?, ledger: ExtractionReplacementLedger) async throws -> URL {
        let operation = FileOperation.extract(archive: archive, format: .rar)
        startOperation(operation, totalCount: 1)
        let cancellation = CancelFlag()
        currentCancelFlag = cancellation
        defer { finishOperation() }
        let parent = archive.deletingLastPathComponent()
        enterProtectedPaths([parent])
        defer { leaveProtectedPaths([parent]) }
        let progress: @Sendable (UInt64) throws -> Void = { [weak self] bytes in
            guard !cancellation.isCancelled else { throw FileOperationError.cancelled }
            try Task.checkCancellation()
            Task { @MainActor [weak self] in
                guard let self, self.currentCancelFlag === cancellation else { return }
                self.updateProgress(operation: operation, currentItem: archive, completed: 0, total: 1,
                                    bytesCompleted: Int64(clamping: bytes))
            }
        }
        #if DEBUG
        let probe = rarExtractionProbeForTesting
        let forceFallback = forceLocalDisplacementFallbackForTesting
        #else
        let forceFallback = false
        #endif
        let staged = try await runFileIO {
            let directory = try OperationDirectory(path: Data(parent.path.utf8))
            let volumes = try RarVolumeSet.discover(directory: directory, selected: archive.lastPathComponent,
                                                   password: password, progress: progress)
            #if DEBUG
            try probe?(.discovered, cancellation)
            #endif
            let values = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey, .volumeAvailableCapacityForImportantUsageKey])
            return try RarExtractionStaging(volumes: volumes, password: password,
                caseSensitive: values.volumeSupportsCaseSensitiveNames == true,
                availableBytes: values.volumeAvailableCapacityForImportantUsage, progress: progress, beforeOutput: {
                    #if DEBUG
                    try probe?(.output, cancellation)
                    #endif
                })
        }
        do {
            #if DEBUG
            try probe?(.prepared, cancellation)
            #endif
            try checkCancelled()
            let name = staged.plan.singleRoot ?? staged.volumes.baseName
            guard !name.isEmpty else { throw SevenZipArchiveError.invalidEntry }
            var destination = parent.appendingPathComponent(name)
            let directory = staged.volumes.directory
            var occupant: OperationObservation?
            switch try directory.lookup(Data(name.utf8)) {
            case .found(let observed):
                let choice = await resolveExtractConflict(conflictingItems: [name], destination: parent)
                switch choice {
                case .stop: throw FileOperationError.cancelled
                case .replace:
                    guard !staged.volumes.parts.contains(where: { $0.observation.identity == observed.identity }) else {
                        throw SevenZipArchiveError.invalidEntry
                    }
                    occupant = observed
                case .keepBoth:
                    destination = staged.manifest.entries.first?.observation.kind == .directory
                        ? uniqueFolderDestination(in: parent, baseName: name)
                        : uniqueFileDestination(in: parent, baseName: name)
                }
            case .missing: break
            case .denied: throw POSIXError(.EACCES)
            case .disconnected: throw POSIXError(.ENOTCONN)
            case .unsupported: throw OperationFilesystemError.unsupported
            }
            try checkCancelled()
            let finalDestination = destination
            let expectedOccupant = occupant
            let displaced = try await runFileIO {
                #if DEBUG
                try probe?(.publishing, cancellation)
                #endif
                try staged.validate(progress: progress)
                let target = Data(finalDestination.lastPathComponent.utf8)
                if let expectedOccupant {
                    guard case .found(let current) = try directory.lookup(target), current == expectedOccupant else {
                        throw OperationFilesystemError.identityChanged
                    }
                } else {
                    guard case .missing = try directory.lookup(target) else { throw OperationFilesystemError.identityChanged }
                }
                try progress(0)
                var displaced: LocalDisplacedItem?
                do {
                    if expectedOccupant != nil {
                        displaced = try Self.displaceLocalItemSync(finalDestination, forceFallback: forceFallback)
                    }
                    try progress(0)
                    guard let payload = staged.manifest.entries.first?.observation else { throw SevenZipArchiveError.invalidEntry }
                    _ = try staged.workspace.directory.moveExclusive(staged.payload, to: directory, named: target, expected: payload)
                    return displaced
                } catch {
                    if let displaced { try Self.restoreLocalDisplacementSync(displaced) }
                    throw error
                }
            }
            if let displaced { ledger.displacedItems.append(displaced) }
            ledger.createdItems.append(destination)
            #if DEBUG
            try probe?(.published, cancellation)
            #endif
            try await runUntrackedFileIO { try staged.workspace.removeScratch() }
            updateProgress(operation: operation, currentItem: destination, completed: 1, total: 1,
                           bytesCompleted: Int64(staged.plan.byteCount), bytesTotal: Int64(staged.plan.byteCount))
            return destination
        } catch {
            do { try await runUntrackedFileIO { try staged.workspace.removeScratch() } } catch let cleanup {
                throw replacementRollbackError(operationError: error, rollbackError: cleanup)
            }
            throw error
        }
    }
}
