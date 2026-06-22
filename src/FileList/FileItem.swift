import AppKit

enum ICloudStatus {
    case local
    case downloaded
    case notDownloaded
    case downloading
}

enum SharedItemRole: Equatable {
    case participant(ownerName: String)
    case owner
}

final class FileItem {
    let name: String
    let location: Location
    var url: URL { location.url }
    var expansionURL: URL {
        switch location {
        case .local(let url):
            return url.standardizedFileURL
        case .remote(_, let path):
            return URL(fileURLWithPath: path).standardizedFileURL
        }
    }
    var isLocal: Bool {
        if case .local = location { return true }
        return false
    }
    var isRemote: Bool {
        if case .remote = location { return true }
        return false
    }
    let isDirectory: Bool
    let isPackage: Bool
    let isAliasFile: Bool
    let isSymbolicLink: Bool
    let isReadable: Bool
    let isHiddenFile: Bool
    let size: Int64?
    let dateModified: Date
    var icon: NSImage
    let sharedRole: SharedItemRole?
    let isVirtualSharedFolder: Bool
    let iCloudStatus: ICloudStatus
    var gitStatus: GitStatus?

    // Tree support for folder expansion
    var children: [FileItem]?  // nil = not loaded, empty = loaded but empty
    weak var parent: FileItem?

    convenience init(name: String, location: Location, isDirectory: Bool, isPackage: Bool = false, isAliasFile: Bool = false, isSymbolicLink: Bool = false, isReadable: Bool = true, size: Int64?, dateModified: Date, icon: NSImage, sharedRole: SharedItemRole? = nil, isVirtualSharedFolder: Bool = false, iCloudStatus: ICloudStatus = .local, isHiddenFile: Bool = false, gitStatus: GitStatus? = nil) {
        switch location {
        case .local(let url):
            self.init(
                name: name,
                url: url,
                isDirectory: isDirectory,
                isPackage: isPackage,
                isAliasFile: isAliasFile,
                isSymbolicLink: isSymbolicLink,
                isReadable: isReadable,
                size: size,
                dateModified: dateModified,
                icon: icon,
                sharedRole: sharedRole,
                isVirtualSharedFolder: isVirtualSharedFolder,
                iCloudStatus: iCloudStatus,
                isHiddenFile: isHiddenFile,
                gitStatus: gitStatus
            )
        case .remote:
            self.init(
                name: name,
                location: location,
                isDirectory: isDirectory,
                isPackage: isPackage,
                isAliasFile: isAliasFile,
                isSymbolicLink: isSymbolicLink,
                isReadable: isReadable,
                size: size,
                dateModified: dateModified,
                icon: icon,
                sharedRole: sharedRole,
                isVirtualSharedFolder: isVirtualSharedFolder,
                iCloudStatus: iCloudStatus,
                isHiddenFile: isHiddenFile,
                gitStatus: gitStatus,
                remoteToken: ()
            )
        }
    }

    init(name: String, url: URL, isDirectory: Bool, isPackage: Bool = false, isAliasFile: Bool = false, isSymbolicLink: Bool = false, isReadable: Bool = true, size: Int64?, dateModified: Date, icon: NSImage, sharedRole: SharedItemRole? = nil, isVirtualSharedFolder: Bool = false, iCloudStatus: ICloudStatus = .local, isHiddenFile: Bool = false, gitStatus: GitStatus? = nil) {
        self.name = name
        self.location = .local(url)
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAliasFile = isAliasFile
        self.isSymbolicLink = isSymbolicLink
        self.isReadable = isReadable
        self.isHiddenFile = isHiddenFile
        self.size = size
        self.dateModified = dateModified
        self.icon = icon
        self.sharedRole = sharedRole
        self.isVirtualSharedFolder = isVirtualSharedFolder
        self.iCloudStatus = iCloudStatus
        self.gitStatus = gitStatus
    }

    private init(name: String, location: Location, isDirectory: Bool, isPackage: Bool, isAliasFile: Bool, isSymbolicLink: Bool, isReadable: Bool, size: Int64?, dateModified: Date, icon: NSImage, sharedRole: SharedItemRole?, isVirtualSharedFolder: Bool, iCloudStatus: ICloudStatus, isHiddenFile: Bool, gitStatus: GitStatus?, remoteToken: Void) {
        self.name = name
        self.location = location
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAliasFile = isAliasFile
        self.isSymbolicLink = isSymbolicLink
        self.isReadable = isReadable
        self.isHiddenFile = isHiddenFile
        self.size = size
        self.dateModified = dateModified
        self.icon = icon
        self.sharedRole = sharedRole
        self.isVirtualSharedFolder = isVirtualSharedFolder
        self.iCloudStatus = iCloudStatus
        self.gitStatus = gitStatus
    }

    init(entry: LoadedFileEntry, icon: NSImage) {
        self.location = entry.location
        self.name = entry.name
        self.isDirectory = entry.isDirectory
        self.isPackage = entry.isPackage
        self.isAliasFile = entry.isAliasFile
        self.isSymbolicLink = entry.isSymbolicLink
        self.isReadable = entry.isReadable
        self.isHiddenFile = entry.isHidden
        self.size = entry.fileSize
        self.dateModified = entry.contentModificationDate
        self.icon = icon

        self.sharedRole = Self.makeSharedRole(
            isShared: entry.ubiquitousItemIsShared,
            role: entry.ubiquitousSharedItemCurrentUserRole,
            ownerComponents: entry.ubiquitousSharedItemOwnerNameComponents
        )
        self.isVirtualSharedFolder = false

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
        self.location = .local(url)

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey,
            .ubiquitousItemIsSharedKey,
            .ubiquitousSharedItemCurrentUserRoleKey,
            .ubiquitousSharedItemOwnerNameComponentsKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]

        (url as NSURL).removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: resourceKeys)

        let isDirectory: Bool = {
            if values?.isDirectory == true {
                return true
            }
            if values?.isAliasFile == true || values?.isSymbolicLink == true {
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) {
                    return dir.boolValue
                }
            }
            return false
        }()

        self.name = values?.localizedName ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = values?.isPackage ?? false
        self.isAliasFile = values?.isAliasFile ?? false
        self.isSymbolicLink = values?.isSymbolicLink ?? false
        self.isReadable = values?.isReadable ?? true
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

        self.sharedRole = Self.makeSharedRole(
            isShared: values?.ubiquitousItemIsShared == true,
            role: values?.ubiquitousSharedItemCurrentUserRole,
            ownerComponents: values?.ubiquitousSharedItemOwnerNameComponents
        )
        self.isVirtualSharedFolder = false

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

    private static func makeSharedRole(
        isShared: Bool,
        role: URLUbiquitousSharedItemRole?,
        ownerComponents: PersonNameComponents?
    ) -> SharedItemRole? {
        guard isShared || role != nil else { return nil }

        switch role {
        case .owner:
            return .owner
        case .participant:
            let ownerName = ownerComponents?.formatted(.name(style: .short)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let ownerName, !ownerName.isEmpty {
                return .participant(ownerName: ownerName)
            }
            return .participant(ownerName: "someone")
        case nil:
            let ownerName = ownerComponents?.formatted(.name(style: .short)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let ownerName, !ownerName.isEmpty {
                return .participant(ownerName: ownerName)
            }
            return .participant(ownerName: "someone")
        default:
            return nil
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
        let formatter = DateFormatter()
        let settings = Self.currentSettingsSnapshot()

        if calendar.isDate(dateModified, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = settings.dateFormatCurrentYear
        } else {
            formatter.dateFormat = settings.dateFormatOtherYears
        }
        return formatter.string(from: dateModified)
    }

    private static func currentSettingsSnapshot() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: "Detours.Settings"),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return decoded
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

            // Clear stale NSURL resource value cache on removable volumes
            // so sizes from a previously-mounted volume aren't shown.
            let isRemovable = DirectoryLoader.isRemovableVolume(url)
            let items = FileItem.sorted(contents.map { childURL -> FileItem in
                var fileURL = childURL
                if isRemovable {
                    fileURL.removeAllCachedResourceValues()
                }
                return FileItem(url: fileURL)
            }, by: sortDescriptor, foldersOnTop: foldersOnTop)
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
    @MainActor
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
        switch location {
        case .local(let url):
            return isDirectory && !isPackage && !FileOpenHelper.isDiskImage(url)
        case .remote:
            return isDirectory && !isPackage
        }
    }

    var sharedLabelText: String? {
        switch sharedRole {
        case .participant(let ownerName):
            return "Shared by \(ownerName)"
        case .owner:
            return "Shared by me"
        case nil:
            return nil
        }
    }

    /// Returns the resolved directory URL if this item can accept dropped files.
    /// For directories, returns self.url. For Finder aliases to directories, returns the resolved target.
    /// Returns nil if this item is not a valid drop target.
    var dropDestination: URL? {
        guard !isVirtualSharedFolder else { return nil }
        guard case .local(let url) = location else { return nil }
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
        lhs.location == rhs.location
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(location)
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

            // Use AppKit drawing state here; icon rendering can happen from AppKit callbacks
            // that are not in Swift's MainActor executor context.
            let accentColor = Theme.currentFolderAccentColor()

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
