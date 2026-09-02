import Foundation

/// Path checks that never follow a symbolic link, so a link and a dangling link
/// are seen as what they are on disk.
enum PathProbe {
    static func mode(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    static func existsWithoutFollowing(_ path: String) -> Bool {
        mode(of: path) != nil
    }

    static func isSymbolicLink(_ path: String) -> Bool {
        guard let mode = mode(of: path) else { return false }
        return (mode & S_IFMT) == S_IFLNK
    }
}
