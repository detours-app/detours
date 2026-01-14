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

    /// Mounts a disk image using hdiutil
    @MainActor
    static func mountDiskImage(_ url: URL) {
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["attach", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                await MainActor.run {
                    logger.error("Failed to mount disk image: \(error.localizedDescription)")
                }
            }
        }
    }
}
