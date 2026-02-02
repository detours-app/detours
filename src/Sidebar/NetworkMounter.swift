import AppKit
import NetFS
import os.log

private let logger = Logger(subsystem: "com.detours", category: "network-mounter")

// MARK: - Network Mount Error

enum NetworkMountError: LocalizedError {
    case authenticationFailed
    case serverUnreachable
    case permissionDenied
    case cancelled
    case invalidURL
    case mountFailed(Int32)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Authentication failed. Please check your username and password."
        case .serverUnreachable:
            return "Could not connect to the server. Verify the server is online and reachable."
        case .permissionDenied:
            return "Permission denied. You don't have access to this share."
        case .cancelled:
            return "Mount operation was cancelled."
        case .invalidURL:
            return "Invalid server URL."
        case .mountFailed(let code):
            return "Mount failed with error code \(code)."
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Network Mounter

@MainActor
final class NetworkMounter {
    static let shared = NetworkMounter()

    private init() {}

    // MARK: - Mount

    /// Mount a network server, optionally with credentials
    /// - Parameters:
    ///   - url: The server URL (smb://host/share or nfs://host/export)
    ///   - username: Optional username for authentication
    ///   - password: Optional password for authentication
    /// - Returns: The mount point URL on success
    func mount(
        url: URL,
        username: String? = nil,
        password: String? = nil
    ) async throws -> URL {
        guard url.scheme == "smb" || url.scheme == "nfs" else {
            throw NetworkMountError.invalidURL
        }

        logger.info("Mounting \(url.absoluteString)")

        // Snapshot volumes before mount to detect new mount point
        let volumesBefore = Set(self.currentVolumes())

        return try await withCheckedThrowingContinuation { continuation in
            var mountPoints: Unmanaged<CFArray>?

            // Set up options as mutable dictionaries (required by NetFS)
            let openOptions = NSMutableDictionary()
            let mountOptions = NSMutableDictionary()

            // Set up authentication if provided
            if username != nil {
                openOptions[kNetFSUseAuthenticationInfoKey] = true
                openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
            }

            // Allow soft mounts for better behavior on network issues
            mountOptions[kNetFSSoftMountKey] = true

            // Prepare mount directory (NetFS will create a subdirectory in /Volumes)
            let mountDir = URL(fileURLWithPath: "/Volumes")

            // Build the NetFS call on the main queue
            let result = NetFSMountURLSync(
                url as CFURL,
                mountDir as CFURL,
                username as CFString?,
                password as CFString?,
                openOptions as CFMutableDictionary,
                mountOptions as CFMutableDictionary,
                &mountPoints
            )

            if result == 0 {
                // Success - extract mount point
                if let points = mountPoints?.takeRetainedValue() as? [URL],
                   let mountPoint = points.first {
                    logger.info("Mounted at \(mountPoint.path)")
                    continuation.resume(returning: mountPoint)
                } else {
                    // No mount point returned but success - find the new volume
                    let volumesAfter = Set(self.currentVolumes())
                    let newVolumes = volumesAfter.subtracting(volumesBefore)

                    if let mountPoint = newVolumes.first {
                        logger.info("Mounted at \(mountPoint.path) (detected by diff)")
                        continuation.resume(returning: mountPoint)
                    } else {
                        // Volume was already mounted - find it by URL match
                        if let mountPoint = self.findMountPoint(for: url) {
                            logger.info("Already mounted at \(mountPoint.path)")
                            continuation.resume(returning: mountPoint)
                        } else {
                            continuation.resume(throwing: NetworkMountError.unknown("Mount succeeded but mount point not found"))
                        }
                    }
                }
            } else {
                // Map error codes to our error types
                let error = self.mapNetFSError(result)
                logger.error("Mount failed: \(error.localizedDescription)")
                continuation.resume(throwing: error)
            }
        }
    }

    /// Mount a discovered network server
    func mount(
        server: NetworkServer,
        username: String? = nil,
        password: String? = nil
    ) async throws -> URL {
        guard let url = server.url else {
            throw NetworkMountError.invalidURL
        }
        return try await mount(url: url, username: username, password: password)
    }

    // MARK: - Unmount

    /// Unmount a network volume
    func unmount(mountPoint: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: mountPoint)
                logger.info("Unmounted \(mountPoint.path)")
                continuation.resume()
            } catch {
                logger.error("Unmount failed: \(error.localizedDescription)")
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Helpers

    private func mapNetFSError(_ code: Int32) -> NetworkMountError {
        switch code {
        case EAUTH, EPERM:
            return .authenticationFailed
        case ENOENT, EHOSTUNREACH, ENETUNREACH, ETIMEDOUT:
            return .serverUnreachable
        case EACCES:
            return .permissionDenied
        case ECANCELED:
            return .cancelled
        default:
            return .mountFailed(code)
        }
    }

    private func currentVolumes() -> [URL] {
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        return (try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func findMountPoint(for url: URL) -> URL? {
        guard let host = url.host else { return nil }

        let volumes = currentVolumes()
        let shareName = url.lastPathComponent

        // Look for exact share name match first
        if !shareName.isEmpty {
            if let match = volumes.first(where: { $0.lastPathComponent == shareName }) {
                return match
            }
        }

        // Then try host name match
        if let match = volumes.first(where: {
            $0.lastPathComponent.lowercased() == host.lowercased()
        }) {
            return match
        }

        // Finally try partial host match
        if let match = volumes.first(where: {
            $0.lastPathComponent.lowercased().contains(host.lowercased())
        }) {
            return match
        }

        return nil
    }
}
