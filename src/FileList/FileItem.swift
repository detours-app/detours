import AppKit

enum ICloudStatus {
    case local
    case downloaded
    case notDownloaded
    case downloading
}

final class FileItem {
    let name: String
    let url: URL
    let isDirectory: Bool
    let isPackage: Bool
    let isAliasFile: Bool
    let isHiddenFile: Bool
    let size: Int64?
    let dateModified: Date
    var icon: NSImage
    let sharedByName: String?
    let iCloudStatus: ICloudStatus
    var gitStatus: GitStatus?

    // Tree support for folder expansion
    var children: [FileItem]?  // nil = not loaded, empty = loaded but empty
    weak var parent: FileItem?

    init(name: String, url: URL, isDirectory: Bool, isPackage: Bool = false, isAliasFile: Bool = false, size: Int64?, dateModified: Date, icon: NSImage, sharedByName: String? = nil, iCloudStatus: ICloudStatus = .local, isHiddenFile: Bool = false, gitStatus: GitStatus? = nil) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAliasFile = isAliasFile
        self.isHiddenFile = isHiddenFile
        self.size = size
        self.dateModified = dateModified
        self.icon = icon
        self.sharedByName = sharedByName
        self.iCloudStatus = iCloudStatus
        self.gitStatus = gitStatus
    }

    init(entry: LoadedFileEntry, icon: NSImage) {
        self.url = entry.url

        // Show "Shared" for iCloud Drive folder (com~apple~CloudDocs)
        if entry.url.lastPathComponent == "com~apple~CloudDocs" {
            self.name = "Shared"
        } else {
            self.name = entry.name
        }
        self.isDirectory = entry.isDirectory
        self.isPackage = entry.isPackage
        self.isAliasFile = entry.isAliasFile
        self.isHiddenFile = entry.isHidden
        self.size = entry.fileSize
        self.dateModified = entry.contentModificationDate
        self.icon = icon

        // Show "Shared by X" if shared and we're not the owner
        if entry.ubiquitousItemIsShared,
           entry.ubiquitousSharedItemCurrentUserRole == .participant,
           let ownerComponents = entry.ubiquitousSharedItemOwnerNameComponents {
            self.sharedByName = ownerComponents.formatted(.name(style: .short))
        } else {
            self.sharedByName = nil
        }

        // Determine iCloud download status
        if entry.ubiquitousItemIsDownloading {
            self.iCloudStatus = .downloading
        } else if let status = entry.ubiquitousItemDownloadingStatus {
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

        self.gitStatus = nil
    }

    /// Synchronous init that reads resource values from the file system directly.
    /// Blocks the calling thread — prefer init(entry:icon:) for async paths.
    init(url: URL) {
        self.url = url

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isAliasFileKey,
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
        self.isPackage = values?.isPackage ?? false
        self.isAliasFile = values?.isAliasFile ?? false
        self.isHiddenFile = url.lastPathComponent.hasPrefix(".")
        self.size = isDirectory ? nil : Int64(values?.fileSize ?? 0)
        self.dateModified = values?.contentModificationDate ?? Date()

        // Get system icon and tint folders (but not packages) with accent color
        let systemIcon = NSWorkspace.shared.icon(forFile: url.path)
        if self.isDirectory && !self.isPackage {
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

        // Git status is set externally by data source
        self.gitStatus = nil
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
        let formatter = DateFormatter()

        if calendar.isDate(dateModified, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = MainActor.assumeIsolated { SettingsManager.shared.dateFormatCurrentYear }
        } else {
            formatter.dateFormat = MainActor.assumeIsolated { SettingsManager.shared.dateFormatOtherYears }
        }
        return formatter.string(from: dateModified)
    }

    // MARK: - Tree Operations

    /// Loads children for this directory. Returns nil for files.
    /// Empty array means directory is empty (not same as nil which means not loaded).
    /// If children are already loaded, returns existing children without reloading.
    func loadChildren(showHidden: Bool, sortDescriptor: SortDescriptor = .defaultSort, foldersOnTop: Bool = true) -> [FileItem]? {
        guard isNavigableFolder else { return nil }

        // Return existing children if already loaded to preserve object identity
        // (important for NSOutlineView which tracks items by identity)
        if let existingChildren = children {
            return existingChildren
        }

        do {
            var options: FileManager.DirectoryEnumerationOptions = []
            if !showHidden {
                options.insert(.skipsHiddenFiles)
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: options
            )

            let items = FileItem.sorted(contents.map { FileItem(url: $0) }, by: sortDescriptor, foldersOnTop: foldersOnTop)
            // Set parent reference on all children
            for item in items {
                item.parent = self
            }
            children = items
            return items
        } catch {
            // Permission denied or other error - return empty array (not nil)
            children = []
            return []
        }
    }

    /// Async version of loadChildren for network volumes.
    /// Loads children on a background thread via DirectoryLoader.
    func loadChildrenAsync(showHidden: Bool, sortDescriptor: SortDescriptor = .defaultSort, foldersOnTop: Bool = true) async throws -> [FileItem]? {
        guard isNavigableFolder else { return nil }

        if let existingChildren = children {
            return existingChildren
        }

        let entries = try await DirectoryLoader.shared.loadChildren(url, showHidden: showHidden)

        let items = entries.map { entry -> FileItem in
            let placeholder: NSImage
            if entry.isDirectory && !entry.isPackage {
                placeholder = Self.tintedFolderIcon(IconLoader.placeholderFolderIcon)
            } else {
                placeholder = IconLoader.placeholderFileIcon
            }
            return FileItem(entry: entry, icon: placeholder)
        }

        let sorted = FileItem.sorted(items, by: sortDescriptor, foldersOnTop: foldersOnTop)
        for item in sorted {
            item.parent = self
        }
        children = sorted
        return sorted
    }

    /// Clears loaded children (for refresh)
    func clearChildren() {
        children = nil
    }
}

// MARK: - Sort Types

enum SortColumn: String, Codable {
    case name
    case size
    case dateModified
}

struct SortDescriptor: Equatable {
    var column: SortColumn
    var ascending: Bool

    static let defaultSort = SortDescriptor(column: .name, ascending: true)
}

// MARK: - Sorting

extension FileItem {
    /// True if this is a navigable folder (directory but not a package or disk image)
    var isNavigableFolder: Bool {
        isDirectory && !isPackage && !FileOpenHelper.isDiskImage(url)
    }

    /// Returns the resolved directory URL if this item can accept dropped files.
    /// For directories, returns self.url. For Finder aliases to directories, returns the resolved target.
    /// Returns nil if this item is not a valid drop target.
    var dropDestination: URL? {
        if isDirectory { return url }
        guard isAliasFile else { return nil }
        guard let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) else { return nil }
        let isDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDir ? resolved : nil
    }

    /// Sorts items by the given descriptor with optional folders-on-top grouping.
    /// Within each group (or all items if foldersOnTop is false), items are sorted by
    /// the specified column and direction. Ties are broken by name for stability.
    static func sorted(_ items: [FileItem], by descriptor: SortDescriptor, foldersOnTop: Bool) -> [FileItem] {
        let comparator: (FileItem, FileItem) -> Bool = { a, b in
            let result: ComparisonResult
            switch descriptor.column {
            case .name:
                result = a.name.localizedCaseInsensitiveCompare(b.name)
            case .size:
                let sizeA = a.size ?? 0
                let sizeB = b.size ?? 0
                if sizeA == sizeB {
                    result = a.name.localizedCaseInsensitiveCompare(b.name)
                } else {
                    result = sizeA < sizeB ? .orderedAscending : .orderedDescending
                }
            case .dateModified:
                if a.dateModified == b.dateModified {
                    result = a.name.localizedCaseInsensitiveCompare(b.name)
                } else {
                    result = a.dateModified < b.dateModified ? .orderedAscending : .orderedDescending
                }
            }
            return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
        }

        if foldersOnTop {
            let folders = items.filter { $0.isNavigableFolder }.sorted(by: comparator)
            let files = items.filter { !$0.isNavigableFolder }.sorted(by: comparator)
            return folders + files
        } else {
            return items.sorted(by: comparator)
        }
    }
}

// MARK: - Hashable

extension FileItem: Hashable {
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

// MARK: - Icon Tinting

extension FileItem {
    /// Creates a tinted version of the folder icon using theme accent color
    static func tintedFolderIcon(_ icon: NSImage) -> NSImage {
        let size = icon.size
        guard size.width > 0, size.height > 0 else { return icon }

        let tinted = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw the original icon
            icon.draw(in: rect)

            // Get accent color and brighten for dark mode
            var accentColor = MainActor.assumeIsolated { ThemeManager.shared.currentTheme.accent }
            let isDark = MainActor.assumeIsolated {
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
            if isDark {
                accentColor = accentColor.brighterForDarkMode()
            }

            // Apply accent color directly for vibrant result
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(accentColor.cgColor)
            ctx.fill(rect)

            return true
        }
        return tinted
    }
}

// MARK: - Color Brightness Adjustment

extension NSColor {
    /// Returns a brighter version of the color for use in dark mode folder icons
    func brighterForDarkMode() -> NSColor {
        guard let color = self.usingColorSpace(.sRGB) else { return self }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Increase brightness by 25%, cap at 1.0
        let newBrightness = min(brightness + 0.25, 1.0)
        // Slightly reduce saturation to avoid oversaturation
        let newSaturation = saturation * 0.9

        return NSColor(hue: hue, saturation: newSaturation, brightness: newBrightness, alpha: alpha)
    }
}
