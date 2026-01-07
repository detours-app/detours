import AppKit

enum ICloudStatus {
    case local
    case downloaded
    case notDownloaded
    case downloading
}

struct FileItem {
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let dateModified: Date
    let icon: NSImage
    let sharedByName: String?
    let iCloudStatus: ICloudStatus

    init(name: String, url: URL, isDirectory: Bool, size: Int64?, dateModified: Date, icon: NSImage, sharedByName: String? = nil, iCloudStatus: ICloudStatus = .local) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.dateModified = dateModified
        self.icon = icon
        self.sharedByName = sharedByName
        self.iCloudStatus = iCloudStatus
    }

    init(url: URL) {
        self.url = url

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey,
            .ubiquitousItemIsSharedKey,
            .ubiquitousSharedItemCurrentUserRoleKey,
            .ubiquitousSharedItemOwnerNameComponentsKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]

        let values = try? url.resourceValues(forKeys: resourceKeys)

        // Show "Shared" for iCloud Drive folder (com~apple~CloudDocs)
        if url.lastPathComponent == "com~apple~CloudDocs" {
            self.name = "Shared"
        } else {
            self.name = values?.localizedName ?? url.lastPathComponent
        }
        self.isDirectory = values?.isDirectory ?? false
        self.size = isDirectory ? nil : Int64(values?.fileSize ?? 0)
        self.dateModified = values?.contentModificationDate ?? Date()

        // Get system icon and tint folders with accent color
        let systemIcon = NSWorkspace.shared.icon(forFile: url.path)
        if self.isDirectory {
            self.icon = Self.tintedFolderIcon(systemIcon)
        } else {
            self.icon = systemIcon
        }

        // Show "Shared by X" if shared and we're not the owner
        if values?.ubiquitousItemIsShared == true,
           values?.ubiquitousSharedItemCurrentUserRole == .participant,
           let ownerComponents = values?.ubiquitousSharedItemOwnerNameComponents {
            self.sharedByName = ownerComponents.formatted(.name(style: .short))
        } else {
            self.sharedByName = nil
        }

        // Determine iCloud download status
        if values?.ubiquitousItemIsDownloading == true {
            self.iCloudStatus = .downloading
        } else if let status = values?.ubiquitousItemDownloadingStatus {
            switch status {
            case .current, .downloaded:
                self.iCloudStatus = .downloaded
            case .notDownloaded:
                self.iCloudStatus = .notDownloaded
            default:
                self.iCloudStatus = .local
            }
        } else {
            self.iCloudStatus = .local
        }
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

// MARK: - Icon Tinting

extension FileItem {
    /// Creates a teal-tinted version of the folder icon preserving shading
    static func tintedFolderIcon(_ icon: NSImage) -> NSImage {
        let size = icon.size
        guard size.width > 0, size.height > 0 else { return icon }

        let tinted = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw the original icon into a layer
            icon.draw(in: rect)

            // Create a tint layer: draw icon as mask, fill with teal
            ctx.saveGState()
            ctx.clip(to: rect, mask: icon.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            ctx.setBlendMode(.color)
            ctx.setFillColor(detourAccentColor.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()

            return true
        }
        return tinted
    }
}
