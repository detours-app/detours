import Foundation

enum RemoteFileCache {
    static let quickLookMaximumBytes: Int64 = 100 * 1_000_000
    static let progressMinimumBytes: Int64 = 1_000_000

    static func makeSessionDirectory(hostID: UUID, sessionID: UUID = UUID()) throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Detours/remote", isDirectory: true)
            .appendingPathComponent(RemoteHost.cacheDirectoryName(hostID: hostID), isDirectory: true)
            .appendingPathComponent("open-\(shortSessionToken(sessionID))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
        return root
    }

    static func makeSessionFile(hostID: UUID, remotePath: String, sessionID: UUID = UUID()) throws -> URL {
        let directory = try makeSessionDirectory(hostID: hostID, sessionID: sessionID)
        return directory.appendingPathComponent(RemoteHost.cacheFileName(remotePath: remotePath), isDirectory: false)
    }

    private static func shortSessionToken(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }
}
