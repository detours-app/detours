import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "fileopen")

/// Helper for opening files with the appropriate method.
/// Handles disk image files (DMG, ISO, sparsebundle) specially due to macOS Sequoia bug.
enum FileOpenHelper {
    /// File types that should use hdiutil instead of NSWorkspace.open
    static let diskImageExtensions: Set<String> = ["dmg", "iso", "sparsebundle", "sparseimage"]

    /// Returns true if the URL should be mounted as a disk image
    static func isDiskImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return diskImageExtensions.contains(ext)
    }

    /// Opens a file with the appropriate method.
    /// Uses hdiutil for disk images (workaround for macOS Sequoia bug where NSWorkspace.open doesn't mount DMGs)
    @MainActor
    static func open(_ url: URL) {
        if isDiskImage(url) {
            mountDiskImage(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a disk image and returns the mount point URL, or nil if mounting failed.
    /// The caller can use this to navigate to the mounted volume.
    static func openAndMount(_ url: URL) async -> URL? {
        guard isDiskImage(url) else {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return nil
        }
        return await mountDiskImageAndGetPath(url)
    }

    /// Mounts a disk image using hdiutil (fire-and-forget, no navigation)
    @MainActor
    static func mountDiskImage(_ url: URL) {
        Task.detached {
            _ = await mountDiskImageAndGetPath(url)
        }
    }

    /// Mounts a disk image and returns the mount point path.
    /// Parses hdiutil plist output to find the mounted volume.
    /// Blocks until mount completes (including any password prompt for encrypted images).
    private static func mountDiskImageAndGetPath(_ url: URL) async -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", url.path, "-plist"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("Failed to mount disk image: \(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            logger.error("hdiutil attach failed with status \(process.terminationStatus)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return parseMountPoint(from: data)
    }

    /// Parses hdiutil -plist output to extract the mount point path.
    private static func parseMountPoint(from data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            return nil
        }

        // Find the entry with a mount-point (skip the disk image itself)
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        return nil
    }
}
