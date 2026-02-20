import Foundation
import os.log

private let logger = Logger(subsystem: "com.detours", category: "directoryloader")

// MARK: - DirectoryLoadError

enum DirectoryLoadError: Error, Equatable {
    case timeout
    case cancelled
    case accessDenied
    case disconnected
    case other(String)
}

// MARK: - LoadedFileEntry

struct LoadedFileEntry: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isAliasFile: Bool
    let isHidden: Bool
    let fileSize: Int64?
    let contentModificationDate: Date
    let ubiquitousItemIsShared: Bool
    let ubiquitousSharedItemCurrentUserRole: URLUbiquitousSharedItemRole?
    let ubiquitousSharedItemOwnerNameComponents: PersonNameComponents?
    let ubiquitousItemDownloadingStatus: URLUbiquitousItemDownloadingStatus?
    let ubiquitousItemIsDownloading: Bool

    init(url: URL, resourceValues values: URLResourceValues?) {
        self.url = url
        self.name = values?.localizedName ?? url.lastPathComponent
        self.isDirectory = values?.isDirectory ?? false
        self.isPackage = values?.isPackage ?? false
        self.isAliasFile = values?.isAliasFile ?? false
        self.isHidden = url.lastPathComponent.hasPrefix(".")
        self.fileSize = (values?.isDirectory ?? false) ? nil : values?.fileSize.map { Int64($0) }
        self.contentModificationDate = values?.contentModificationDate ?? Date()
        self.ubiquitousItemIsShared = values?.ubiquitousItemIsShared ?? false
        self.ubiquitousSharedItemCurrentUserRole = values?.ubiquitousSharedItemCurrentUserRole
        self.ubiquitousSharedItemOwnerNameComponents = values?.ubiquitousSharedItemOwnerNameComponents
        self.ubiquitousItemDownloadingStatus = values?.ubiquitousItemDownloadingStatus
        self.ubiquitousItemIsDownloading = values?.ubiquitousItemIsDownloading ?? false
    }
}

// MARK: - DirectoryLoader

actor DirectoryLoader {
    static let shared = DirectoryLoader()

    private static let baseResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isAliasFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    private static let localResourceKeys: [URLResourceKey] = [
        .localizedNameKey,
    ]

    private static let iCloudResourceKeys: [URLResourceKey] = [
        .ubiquitousItemIsSharedKey,
        .ubiquitousSharedItemCurrentUserRoleKey,
        .ubiquitousSharedItemOwnerNameComponentsKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
    ]

    /// Returns appropriate resource keys based on volume type.
    /// Network volumes get minimal keys (no localizedName, no iCloud).
    /// iCloud paths get iCloud-specific keys.
    /// Local volumes get localizedName for display names.
    static func resourceKeys(for url: URL) -> [URLResourceKey] {
        if VolumeMonitor.isNetworkVolume(url) {
            return baseResourceKeys
        }

        let mobileDocsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents").path
        if url.path.hasPrefix(mobileDocsPath) {
            return baseResourceKeys + localResourceKeys + iCloudResourceKeys
        }
        return baseResourceKeys + localResourceKeys
    }

    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func loadDirectory(
        _ url: URL,
        showHidden: Bool,
        timeout: Duration = .seconds(15)
    ) async throws -> [LoadedFileEntry] {
        try await withThrowingTaskGroup(of: [LoadedFileEntry]?.self) { group in
            group.addTask {
                try await self.enumerateDirectory(url, showHidden: showHidden)
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                return nil // sentinel for timeout
            }

            guard let firstResult = try await group.next() else {
                throw DirectoryLoadError.timeout
            }

            if let entries = firstResult {
                group.cancelAll()
                return entries
            }

            // Timeout finished first
            group.cancelAll()
            throw DirectoryLoadError.timeout
        }
    }

    func loadChildren(
        _ url: URL,
        showHidden: Bool,
        timeout: Duration = .seconds(15)
    ) async throws -> [LoadedFileEntry] {
        try await loadDirectory(url, showHidden: showHidden, timeout: timeout)
    }

    private func enumerateDirectory(
        _ url: URL,
        showHidden: Bool
    ) async throws -> [LoadedFileEntry] {
        try await withCheckedThrowingContinuation { continuation in
            let keys = Self.resourceKeys(for: url)
            operationQueue.addOperation {
                do {
                    var options: FileManager.DirectoryEnumerationOptions = []
                    if !showHidden {
                        options.insert(.skipsHiddenFiles)
                    }

                    let contents = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: keys,
                        options: options
                    )

                    let entries = contents.map { fileURL -> LoadedFileEntry in
                        let values = try? fileURL.resourceValues(forKeys: Set(keys))
                        return LoadedFileEntry(url: fileURL, resourceValues: values)
                    }

                    continuation.resume(returning: entries)
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain {
                        switch error.code {
                        case NSFileReadNoPermissionError:
                            continuation.resume(throwing: DirectoryLoadError.accessDenied)
                        case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                            continuation.resume(throwing: DirectoryLoadError.disconnected)
                        default:
                            continuation.resume(throwing: DirectoryLoadError.other(error.localizedDescription))
                        }
                    } else if error.domain == NSPOSIXErrorDomain {
                        switch error.code {
                        case 1: // EPERM
                            continuation.resume(throwing: DirectoryLoadError.accessDenied)
                        case 13: // EACCES
                            continuation.resume(throwing: DirectoryLoadError.accessDenied)
                        case 2: // ENOENT
                            continuation.resume(throwing: DirectoryLoadError.disconnected)
                        default:
                            continuation.resume(throwing: DirectoryLoadError.other(error.localizedDescription))
                        }
                    } else {
                        continuation.resume(throwing: DirectoryLoadError.other(error.localizedDescription))
                    }
                }
            }
        }
    }
}
