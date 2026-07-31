import Foundation

/// Shared interpretation of archive tool output, used by both the app and the remote
/// helper so the two sides classify identically and cannot drift apart.
public enum ArchiveToolDiagnostics {
    /// Returns the first member path that would escape the extraction destination
    /// (absolute, or containing a ".." component), or nil when all members are safe.
    public static func firstUnsafeMemberPath(_ members: [String]) -> String? {
        for member in members where !member.isEmpty {
            let normalized = member.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            if normalized.hasPrefix("/") || components.contains("..") {
                return member
            }
        }
        return nil
    }

    /// Extracts every "Path = " member line from `7z l -slt` output. With -ba there is
    /// no header block, so pass `requireSeparator: false`; without -ba the archive's own
    /// path appears before the "----------" separator and must be skipped.
    public static func sevenZipListingMemberPaths(_ output: String, requireSeparator: Bool) -> [String] {
        var members: [String] = []
        var seenSeparator = !requireSeparator
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("----------") {
                seenSeparator = true
                continue
            }
            guard seenSeparator, trimmed.hasPrefix("Path = ") else { continue }
            members.append(String(trimmed.dropFirst("Path = ".count)))
        }
        return members
    }

    /// Whether a failed zip tool run (unzip, ditto, zip) indicates a missing or wrong
    /// password. Union of the wordings the bundled macOS and common Linux tools emit:
    /// exit 82 is unzip's dedicated wrong-password status, any mention of "password"
    /// covers the incorrect/wrong/bad/"no password was provided" variants, and exit 1
    /// with "encrypt" covers entries skipped because they are encrypted.
    public static func isZipPasswordFailure(message: String, status: Int32) -> Bool {
        if status == 82 { return true }
        let lowercased = message.lowercased()
        if lowercased.contains("password") { return true }
        return status == 1 && lowercased.contains("encrypt")
    }

    /// Whether a failed 7z run indicates a missing or wrong password.
    public static func isSevenZipPasswordMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("wrong password")
            || lowercased.contains("incorrect password")
            || lowercased.contains("data error in encrypted file")
            || lowercased.contains("cannot open encrypted archive")
    }
}
