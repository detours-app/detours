import Foundation

/// Path checks that never follow a symbolic link, so a link and a dangling link
/// are seen as what they are on disk. Shared by the app and the remote helper.
public enum PathProbe {
    public static func mode(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    public static func existsWithoutFollowing(_ path: String) -> Bool {
        mode(of: path) != nil
    }

    public static func isSymbolicLink(_ path: String) -> Bool {
        mode(of: path).map { ($0 & S_IFMT) == S_IFLNK } ?? false
    }

    /// True for a real directory only; a link to a directory is a link.
    public static func isDirectoryWithoutFollowing(_ path: String) -> Bool {
        mode(of: path).map { ($0 & S_IFMT) == S_IFDIR } ?? false
    }

    /// Resolves links in every component but the last, so the item itself is addressed as
    /// it is on disk: a link stays a link, a dangling link stays addressable.
    public static func resolvingParent(of path: String) -> URL {
        let requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        let parentURL = requestedURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        return parentURL.appendingPathComponent(requestedURL.lastPathComponent)
    }
}
