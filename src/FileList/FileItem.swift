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
    let isPackage: Bool
    let isHiddenFile: Bool
    let size: Int64?
    let dateModified: Date
    let icon: NSImage
    let sharedByName: String?
    let iCloudStatus: ICloudStatus
    var gitStatus: GitStatus?

    init(name: String, url: URL, isDirectory: Bool, isPackage: Bool = false, size: Int64?, dateModified: Date, icon: NSImage, sharedByName: String? = nil, iCloudStatus: ICloudStatus = .local, isHiddenFile: Bool = false, gitStatus: GitStatus? = nil) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHiddenFile = isHiddenFile
        self.size = size
        self.dateModified = dateModified
        self.icon = icon
        self.sharedByName = sharedByName
        self.iCloudStatus = iCloudStatus
        self.gitStatus = gitStatus
    }

    init(url: URL) {
        self.url = url

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
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
}

// MARK: - Sorting

extension FileItem {
    /// True if this is a navigable folder (directory but not a package like .app)
    var isNavigableFolder: Bool {
        isDirectory && !isPackage
    }

    static func sortFoldersFirst(_ items: [FileItem]) -> [FileItem] {
        let folders = items.filter { $0.isNavigableFolder }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let files = items.filter { !$0.isNavigableFolder }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return folders + files
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
