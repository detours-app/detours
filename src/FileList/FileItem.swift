import AppKit

struct FileItem {
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let dateModified: Date
    let icon: NSImage

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        let values = try? url.resourceValues(forKeys: resourceKeys)

        self.isDirectory = values?.isDirectory ?? false
        self.size = isDirectory ? nil : Int64(values?.fileSize ?? 0)
        self.dateModified = values?.contentModificationDate ?? Date()
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Formatted Properties

    var formattedSize: String {
        guard let size = size else { return "—" }

        if size < 1000 {
            return "\(size) B"
        } else if size < 1_000_000 {
            let kb = Double(size) / 1000
            return String(format: "%.1f KB", kb)
        } else if size < 1_000_000_000 {
            let mb = Double(size) / 1_000_000
            return String(format: "%.1f MB", mb)
        } else {
            let gb = Double(size) / 1_000_000_000
            return String(format: "%.1f GB", gb)
        }
    }

    var formattedDate: String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDate(dateModified, equalTo: now, toGranularity: .year) {
            // Same year: "Jan 5"
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: dateModified)
        } else {
            // Different year: "Dec 31, 2025"
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: dateModified)
        }
    }
}

// MARK: - Sorting

extension FileItem {
    static func sortFoldersFirst(_ items: [FileItem]) -> [FileItem] {
        let folders = items.filter { $0.isDirectory }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let files = items.filter { !$0.isDirectory }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return folders + files
    }
}
