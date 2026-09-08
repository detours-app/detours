import Foundation

extension String {
    /// Wraps the string in single quotes so a shell reads it literally.
    /// A single quote inside the string closes the quote, escapes the quote, and reopens it.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
