import AppKit

extension FileListDataSource {
    // MARK: - iCloud Shared Listing Strategy

    /// Shared view is Finder-like union of three sources:
    /// 1) top-level CloudDocs entries marked shared,
    /// 2) CloudDocs database share roots (includes owner shares behind Desktop/Documents links),
    /// 3) Spotlight shared index fallback (surfaces owner shares outside CloudDocs top-level).
    /// Merging dedupes by resolved path so symlink aliases collapse to a single row.
    struct ICloudSharedSources {
        let cloudDocsChildren: [LoadedFileEntry]
        let sharedRootRecords: [ICloudSharedRootRecord]
        let spotlightEntries: [LoadedFileEntry]
    }

    func loadICloudSharedSources(cloudDocsURL: URL, showHidden: Bool) async throws -> ICloudSharedSources {
        async let cloudDocsChildren = loadDirectoryEntries(cloudDocsURL, showHidden: true)
        async let sharedRootRecords = Self.loadICloudSharedRootRecords()
        async let spotlightEntries = Self.loadICloudSharedSpotlightEntries(showHidden: showHidden)
        return ICloudSharedSources(
            cloudDocsChildren: try await cloudDocsChildren,
            sharedRootRecords: await sharedRootRecords,
            spotlightEntries: await spotlightEntries
        )
    }

    func composeICloudSharedTopLevelItems(from sources: ICloudSharedSources, cloudDocsURL: URL, showHidden: Bool) -> [FileItem] {
        composeICloudSharedTopLevelItems(
            cloudDocsChildren: sources.cloudDocsChildren,
            cloudDocsURL: cloudDocsURL,
            sharedRootRecords: sources.sharedRootRecords,
            spotlightEntries: sources.spotlightEntries,
            showHidden: showHidden
        )
    }

    func composeICloudRootItems(rootEntries: [LoadedFileEntry], cloudDocsChildren: [LoadedFileEntry], cloudDocsURL: URL, cloudDocsModifiedDate: Date, showHidden: Bool = true) -> [FileItem] {
        let nonCloudDocsRootEntries = rootEntries.filter { !Self.isCloudDocs($0.url) }
        let cloudDocsPath = cloudDocsURL.standardizedFileURL.path
        let visibleCloudDocsChildren = visibleICloudEntries(cloudDocsChildren, cloudDocsURL: cloudDocsURL, showHidden: showHidden)
        let cloudDocsNonSharedEntries = visibleCloudDocsChildren.filter {
            !isSharedEntry($0) &&
                $0.url.deletingLastPathComponent().standardizedFileURL.path == cloudDocsPath
        }
        var items = baseFileItems(for: dedupeEntries(cloudDocsNonSharedEntries + nonCloudDocsRootEntries))
        items.append(makeVirtualSharedFolder(cloudDocsURL: cloudDocsURL, modifiedDate: cloudDocsModifiedDate))
        return items
    }

    func composeICloudSharedTopLevelItems(
        cloudDocsChildren: [LoadedFileEntry],
        cloudDocsURL: URL,
        sharedRootRecords: [ICloudSharedRootRecord] = [],
        spotlightEntries: [LoadedFileEntry] = [],
        showHidden: Bool = true
    ) -> [FileItem] {
        let cloudDocsPath = cloudDocsURL.standardizedFileURL.path
        let visibleCloudDocsChildren = visibleICloudEntries(cloudDocsChildren, cloudDocsURL: cloudDocsURL, showHidden: showHidden)
        let sharedEntries = visibleCloudDocsChildren.filter {
            isSharedEntry($0) &&
                $0.url.deletingLastPathComponent().standardizedFileURL.path == cloudDocsPath
        }
        let directItems = baseFileItems(for: dedupeEntries(sharedEntries))
        return mergeSharedTopLevelItems(
            directItems: directItems,
            sharedRootRecords: sharedRootRecords,
            spotlightEntries: spotlightEntries,
            cloudDocsURL: cloudDocsURL,
            showHidden: showHidden
        )
    }

    private func mergeSharedTopLevelItems(
        directItems: [FileItem],
        sharedRootRecords: [ICloudSharedRootRecord],
        spotlightEntries: [LoadedFileEntry],
        cloudDocsURL: URL,
        showHidden: Bool
    ) -> [FileItem] {
        var merged = directItems
        var seenPaths = Set(directItems.map { sharedPathKey(for: $0.url) })

        // Database roots are highest-confidence owner-share roots in iCloud metadata.
        for record in sharedRootRecords {
            let itemURL = cloudDocsURL.appendingPathComponent(record.relativePath).standardizedFileURL
            if !showHidden, itemURL.lastPathComponent.hasPrefix(".") {
                continue
            }
            let key = sharedPathKey(for: itemURL)
            if seenPaths.contains(key) {
                continue
            }
            merged.append(makeSharedRootItem(record: record, url: itemURL))
            seenPaths.insert(key)
        }

        // Spotlight supplements shares that may exist outside CloudDocs top-level.
        for entry in spotlightEntries where isSharedEntry(entry) {
            if !showHidden, entry.isHidden {
                continue
            }
            let remappedEntry = remapSpotlightSharedEntry(entry, cloudDocsURL: cloudDocsURL)
            let key = sharedPathKey(for: remappedEntry.url)
            if seenPaths.contains(key) {
                continue
            }
            merged.append(makeFileItem(from: remappedEntry))
            seenPaths.insert(key)
        }

        return merged
    }

    private func sharedPathKey(for url: URL) -> String {
        url.resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
    }

    private func remapSpotlightSharedEntry(_ entry: LoadedFileEntry, cloudDocsURL: URL) -> LoadedFileEntry {
        let remappedURL = cloudDocsAliasedURL(for: entry.url, cloudDocsURL: cloudDocsURL)
        guard remappedURL.standardizedFileURL != entry.url.standardizedFileURL else {
            return entry
        }

        return LoadedFileEntry(
            url: remappedURL,
            name: remappedURL.lastPathComponent,
            isDirectory: entry.isDirectory,
            isPackage: entry.isPackage,
            isAliasFile: entry.isAliasFile,
            isSymbolicLink: entry.isSymbolicLink,
            isHidden: entry.isHidden,
            fileSize: entry.fileSize,
            contentModificationDate: entry.contentModificationDate,
            ubiquitousItemIsShared: entry.ubiquitousItemIsShared,
            ubiquitousSharedItemCurrentUserRole: entry.ubiquitousSharedItemCurrentUserRole,
            ubiquitousSharedItemOwnerNameComponents: entry.ubiquitousSharedItemOwnerNameComponents,
            ubiquitousItemDownloadingStatus: entry.ubiquitousItemDownloadingStatus,
            ubiquitousItemIsDownloading: entry.ubiquitousItemIsDownloading
        )
    }

    private func cloudDocsAliasedURL(for url: URL, cloudDocsURL: URL) -> URL {
        let standardizedCloudDocsURL = cloudDocsURL.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        let sourcePath = standardizedURL.path
        let cloudDocsPath = standardizedCloudDocsURL.path

        if sourcePath == cloudDocsPath || sourcePath.hasPrefix(cloudDocsPath + "/") {
            return standardizedURL
        }

        let symlinkTargets = cloudDocsSymlinkTargets(cloudDocsURL: standardizedCloudDocsURL)
        for (aliasURL, targetURL) in symlinkTargets {
            let targetPath = targetURL.path
            if sourcePath == targetPath {
                return aliasURL.standardizedFileURL
            }
            if sourcePath.hasPrefix(targetPath + "/") {
                let relativePath = String(sourcePath.dropFirst(targetPath.count + 1))
                return aliasURL.appendingPathComponent(relativePath).standardizedFileURL
            }
        }

        return standardizedURL
    }

    private func cloudDocsSymlinkTargets(cloudDocsURL: URL) -> [(aliasURL: URL, targetURL: URL)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cloudDocsURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }

        var targets: [(aliasURL: URL, targetURL: URL)] = []
        for aliasURL in entries {
            let values = try? aliasURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink == true else { continue }

            let targetURL = aliasURL.resolvingSymlinksInPath().standardizedFileURL
            guard targetURL != aliasURL.standardizedFileURL else { continue }
            targets.append((aliasURL.standardizedFileURL, targetURL))
        }

        return targets
    }

    private func makeSharedRootItem(record: ICloudSharedRootRecord, url: URL) -> FileItem {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey,
            .ubiquitousSharedItemOwnerNameComponentsKey,
        ]

        let values = try? url.resourceValues(forKeys: resourceKeys)
        var isDirectory = record.isDirectory
        if values?.isDirectory == true {
            isDirectory = true
        } else if values?.isAliasFile == true || values?.isSymbolicLink == true {
            var directoryFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directoryFlag) {
                isDirectory = directoryFlag.boolValue
            }
        }

        let ownerName = values?.ubiquitousSharedItemOwnerNameComponents?
            .formatted(.name(style: .short))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sharedRole: SharedItemRole
        if record.creatorID == 0 {
            sharedRole = .owner
        } else if let ownerName, !ownerName.isEmpty {
            sharedRole = .participant(ownerName: ownerName)
        } else {
            sharedRole = .participant(ownerName: "someone")
        }

        let icon: NSImage
        if isDirectory {
            icon = FileItem.tintedFolderIcon(IconLoader.placeholderFolderIcon)
        } else {
            icon = IconLoader.placeholderFileIcon
        }

        return FileItem(
            name: values?.localizedName ?? url.lastPathComponent,
            url: url,
            isDirectory: isDirectory,
            isAliasFile: values?.isAliasFile ?? false,
            size: isDirectory ? nil : values?.fileSize.map(Int64.init),
            dateModified: values?.contentModificationDate ?? Date(),
            icon: icon,
            sharedRole: sharedRole
        )
    }

    nonisolated private static func loadICloudSharedRootRecords() async -> [ICloudSharedRootRecord] {
        await Task.detached(priority: .utility) {
            ICloudSharedRootsDatabase.loadSharedRootRecords()
        }.value
    }

    nonisolated private static func loadICloudSharedSpotlightEntries(showHidden: Bool) async -> [LoadedFileEntry] {
        (try? await DirectoryLoader.shared.loadSpotlightSharedItems(showHidden: showHidden)) ?? []
    }

    private func visibleICloudEntries(_ entries: [LoadedFileEntry], cloudDocsURL: URL, showHidden: Bool) -> [LoadedFileEntry] {
        guard !showHidden else { return entries }
        return entries.filter { entry in
            if !entry.isHidden {
                return true
            }
            return isFinderVisibleCloudDocsLink(entry, cloudDocsURL: cloudDocsURL)
        }
    }

    private func isFinderVisibleCloudDocsLink(_ entry: LoadedFileEntry, cloudDocsURL: URL) -> Bool {
        guard entry.isSymbolicLink else { return false }
        guard entry.url.deletingLastPathComponent().standardizedFileURL.path == cloudDocsURL.standardizedFileURL.path else {
            return false
        }
        let name = entry.url.lastPathComponent
        return name == "Desktop" || name == "Documents"
    }

    private func isSharedEntry(_ entry: LoadedFileEntry) -> Bool {
        entry.ubiquitousItemIsShared || entry.ubiquitousSharedItemCurrentUserRole != nil
    }

    func dedupeEntries(_ entries: [LoadedFileEntry]) -> [LoadedFileEntry] {
        var seen: Set<String> = []
        var deduped: [LoadedFileEntry] = []
        for entry in entries {
            let key = entry.url.standardizedFileURL.path
            if seen.insert(key).inserted {
                deduped.append(entry)
            }
        }
        return deduped
    }

    private func makeVirtualSharedFolder(cloudDocsURL: URL, modifiedDate: Date) -> FileItem {
        FileItem(
            name: "Shared",
            url: cloudDocsURL,
            isDirectory: true,
            size: nil,
            dateModified: modifiedDate,
            icon: FileItem.tintedFolderIcon(IconLoader.placeholderFolderIcon),
            isVirtualSharedFolder: true
        )
    }

    static func isMobileDocuments(_ url: URL) -> Bool {
        let mobileDocsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents").standardizedFileURL.path
        return url.standardizedFileURL.path == mobileDocsPath
    }

    static func cloudDocsURL(for baseURL: URL) -> URL {
        if isCloudDocs(baseURL) {
            return baseURL.standardizedFileURL
        }

        if isMobileDocuments(baseURL) {
            return baseURL.appendingPathComponent("com~apple~CloudDocs").standardizedFileURL
        }

        let mobileDocsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents")
            .standardizedFileURL
        return mobileDocsRoot.appendingPathComponent("com~apple~CloudDocs").standardizedFileURL
    }

    static func isCloudDocs(_ url: URL) -> Bool {
        url.lastPathComponent == "com~apple~CloudDocs"
    }
}
