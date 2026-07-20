import XCTest
@testable import Detours

@MainActor
extension FileListDataSourceTests {
    func testICloudRootExcludesTopLevelSharedItems() {
        let dataSource = FileListDataSource()
        let mobileDocs = URL(fileURLWithPath: "/tmp/Mobile Documents")
        let cloudDocs = mobileDocs.appendingPathComponent("com~apple~CloudDocs")

        let rootEntries = [
            makeEntry(url: cloudDocs, isDirectory: true),
            makeEntry(url: mobileDocs.appendingPathComponent("com~apple~Automator"), isDirectory: true),
        ]
        let cloudDocsChildren = [
            makeEntry(url: cloudDocs.appendingPathComponent("Shared Item"), isDirectory: true, isShared: true, role: .participant),
            makeEntry(url: cloudDocs.appendingPathComponent("Documents"), isDirectory: true, isShared: false),
        ]

        let items = dataSource.composeICloudRootItems(
            rootEntries: rootEntries,
            cloudDocsChildren: cloudDocsChildren,
            cloudDocsURL: cloudDocs,
            cloudDocsModifiedDate: Date(),
            showHidden: false
        )

        XCTAssertFalse(items.contains { $0.url.standardizedFileURL == cloudDocsChildren[0].url.standardizedFileURL })
        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == cloudDocsChildren[1].url.standardizedFileURL })
    }

    func testICloudRootIncludesDedicatedSharedFolder() {
        let dataSource = FileListDataSource()
        let mobileDocs = URL(fileURLWithPath: "/tmp/Mobile Documents")
        let cloudDocs = mobileDocs.appendingPathComponent("com~apple~CloudDocs")

        let items = dataSource.composeICloudRootItems(
            rootEntries: [makeEntry(url: cloudDocs, isDirectory: true)],
            cloudDocsChildren: [],
            cloudDocsURL: cloudDocs,
            cloudDocsModifiedDate: Date(),
            showHidden: false
        )

        XCTAssertTrue(items.contains { $0.isVirtualSharedFolder && $0.name == "Shared" && $0.url.standardizedFileURL == cloudDocs.standardizedFileURL })
    }

    func testSharedModeShowsTopLevelOnly() {
        let dataSource = FileListDataSource()
        let cloudDocs = URL(fileURLWithPath: "/tmp/Mobile Documents/com~apple~CloudDocs")
        let topLevel = makeEntry(url: cloudDocs.appendingPathComponent("Shared Folder"), isDirectory: true, isShared: true, role: .participant)
        let nested = makeEntry(url: cloudDocs.appendingPathComponent("Shared Folder/Nested"), isDirectory: true, isShared: true, role: .participant)

        let items = dataSource.composeICloudSharedTopLevelItems(cloudDocsChildren: [topLevel, nested], cloudDocsURL: cloudDocs, showHidden: false)

        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == topLevel.url.standardizedFileURL })
        XCTAssertFalse(items.contains { $0.url.standardizedFileURL == nested.url.standardizedFileURL })
    }

    func testSharedModeIncludesFilesAndFolders() {
        let dataSource = FileListDataSource()
        let cloudDocs = URL(fileURLWithPath: "/tmp/Mobile Documents/com~apple~CloudDocs")
        let sharedFolder = makeEntry(url: cloudDocs.appendingPathComponent("Shared Folder"), isDirectory: true, isShared: true, role: .owner)
        let sharedFile = makeEntry(url: cloudDocs.appendingPathComponent("Shared File.txt"), isDirectory: false, isShared: true, role: .participant)

        let items = dataSource.composeICloudSharedTopLevelItems(cloudDocsChildren: [sharedFolder, sharedFile], cloudDocsURL: cloudDocs, showHidden: false)

        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == sharedFolder.url.standardizedFileURL && $0.isDirectory })
        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == sharedFile.url.standardizedFileURL && !$0.isDirectory })
    }

    func testShowHiddenAffectsICloudModes() {
        let dataSource = FileListDataSource()
        let mobileDocs = URL(fileURLWithPath: "/tmp/Mobile Documents")
        let cloudDocs = mobileDocs.appendingPathComponent("com~apple~CloudDocs")
        let visibleNormal = makeEntry(url: cloudDocs.appendingPathComponent("Documents"), isDirectory: true, isShared: false)
        let hiddenNormal = makeEntry(url: cloudDocs.appendingPathComponent(".Internal"), isDirectory: true, isShared: false, isHidden: true)
        let visibleShared = makeEntry(url: cloudDocs.appendingPathComponent("Shared.txt"), isDirectory: false, isShared: true, role: .participant)
        let hiddenShared = makeEntry(url: cloudDocs.appendingPathComponent(".SharedHidden"), isDirectory: false, isShared: true, role: .participant, isHidden: true)

        let rootEntries = [makeEntry(url: cloudDocs, isDirectory: true)]
        let cloudDocsChildren = [visibleNormal, hiddenNormal, visibleShared, hiddenShared]

        let hiddenOffRoot = dataSource.composeICloudRootItems(
            rootEntries: rootEntries,
            cloudDocsChildren: cloudDocsChildren,
            cloudDocsURL: cloudDocs,
            cloudDocsModifiedDate: Date(),
            showHidden: false
        )
        let hiddenOnRoot = dataSource.composeICloudRootItems(
            rootEntries: rootEntries,
            cloudDocsChildren: cloudDocsChildren,
            cloudDocsURL: cloudDocs,
            cloudDocsModifiedDate: Date(),
            showHidden: true
        )

        XCTAssertTrue(hiddenOffRoot.contains { $0.url.standardizedFileURL == visibleNormal.url.standardizedFileURL })
        XCTAssertFalse(hiddenOffRoot.contains { $0.url.standardizedFileURL == hiddenNormal.url.standardizedFileURL })
        XCTAssertTrue(hiddenOnRoot.contains { $0.url.standardizedFileURL == hiddenNormal.url.standardizedFileURL })

        let hiddenOffShared = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: cloudDocsChildren,
            cloudDocsURL: cloudDocs,
            showHidden: false
        )
        let hiddenOnShared = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: cloudDocsChildren,
            cloudDocsURL: cloudDocs,
            showHidden: true
        )

        XCTAssertTrue(hiddenOffShared.contains { $0.url.standardizedFileURL == visibleShared.url.standardizedFileURL })
        XCTAssertFalse(hiddenOffShared.contains { $0.url.standardizedFileURL == hiddenShared.url.standardizedFileURL })
        XCTAssertTrue(hiddenOnShared.contains { $0.url.standardizedFileURL == hiddenShared.url.standardizedFileURL })
    }

    func testICloudRootIncludesDesktopDocumentsLinksWhenHidden() {
        let dataSource = FileListDataSource()
        let mobileDocs = URL(fileURLWithPath: "/tmp/Mobile Documents")
        let cloudDocs = mobileDocs.appendingPathComponent("com~apple~CloudDocs")
        let desktopLink = makeEntry(
            url: cloudDocs.appendingPathComponent("Desktop"),
            isDirectory: false,
            isHidden: true,
            isSymbolicLink: true
        )
        let documentsLink = makeEntry(
            url: cloudDocs.appendingPathComponent("Documents"),
            isDirectory: false,
            isHidden: true,
            isSymbolicLink: true
        )

        let items = dataSource.composeICloudRootItems(
            rootEntries: [makeEntry(url: cloudDocs, isDirectory: true)],
            cloudDocsChildren: [desktopLink, documentsLink],
            cloudDocsURL: cloudDocs,
            cloudDocsModifiedDate: Date(),
            showHidden: false
        )

        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == desktopLink.url.standardizedFileURL })
        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == documentsLink.url.standardizedFileURL })
    }

    func testRoleOnlySharedEntriesAppearInSharedMode() {
        let dataSource = FileListDataSource()
        let cloudDocs = URL(fileURLWithPath: "/tmp/Mobile Documents/com~apple~CloudDocs")
        let roleOnlyShared = makeEntry(
            url: cloudDocs.appendingPathComponent("Owner Share"),
            isDirectory: true,
            isShared: false,
            role: .owner
        )

        let rootItems = dataSource.composeICloudRootItems(
            rootEntries: [makeEntry(url: cloudDocs, isDirectory: true)],
            cloudDocsChildren: [roleOnlyShared],
            cloudDocsURL: cloudDocs,
            cloudDocsModifiedDate: Date(),
            showHidden: false
        )
        XCTAssertFalse(rootItems.contains { $0.url.standardizedFileURL == roleOnlyShared.url.standardizedFileURL })

        let sharedItems = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: [roleOnlyShared],
            cloudDocsURL: cloudDocs,
            showHidden: false
        )
        XCTAssertTrue(sharedItems.contains { $0.url.standardizedFileURL == roleOnlyShared.url.standardizedFileURL })
    }

    func testSharedModeIncludesDatabaseShareRootsOutsideCloudDocsTopLevel() {
        let dataSource = FileListDataSource()
        let cloudDocs = URL(fileURLWithPath: "/tmp/Mobile Documents/com~apple~CloudDocs")
        let records = [
            ICloudSharedRootRecord(
                relativePath: "Documents/2 Areas/Assistance/Finance/Tanja/Steuern Tanja",
                creatorID: 0,
                isDirectory: true
            ),
            ICloudSharedRootRecord(
                relativePath: "Documents/2 Areas/Carfo/zCarfo Shared",
                creatorID: 0,
                isDirectory: true
            ),
        ]

        let items = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: [],
            cloudDocsURL: cloudDocs,
            sharedRootRecords: records,
            showHidden: false
        )

        let steuernURL = cloudDocs.appendingPathComponent("Documents/2 Areas/Assistance/Finance/Tanja/Steuern Tanja").standardizedFileURL
        let zCarfoURL = cloudDocs.appendingPathComponent("Documents/2 Areas/Carfo/zCarfo Shared").standardizedFileURL

        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == steuernURL })
        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == zCarfoURL })
        XCTAssertEqual(items.first(where: { $0.url.standardizedFileURL == steuernURL })?.sharedLabelText, "Shared by me")
        XCTAssertEqual(items.first(where: { $0.url.standardizedFileURL == zCarfoURL })?.sharedLabelText, "Shared by me")
    }

    func testSharedModeDedupesDatabaseShareRootsAgainstDirectEntries() {
        let dataSource = FileListDataSource()
        let cloudDocs = URL(fileURLWithPath: "/tmp/Mobile Documents/com~apple~CloudDocs")
        let sharedFolder = makeEntry(
            url: cloudDocs.appendingPathComponent("Steuerbelege"),
            isDirectory: true,
            isShared: true,
            role: .participant
        )
        let records = [
            ICloudSharedRootRecord(
                relativePath: "Steuerbelege",
                creatorID: 2,
                isDirectory: true
            ),
        ]

        let items = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: [sharedFolder],
            cloudDocsURL: cloudDocs,
            sharedRootRecords: records,
            showHidden: false
        )

        XCTAssertEqual(items.filter { $0.url.standardizedFileURL == sharedFolder.url.standardizedFileURL }.count, 1)
    }

    func testSharedModeIncludesSpotlightOwnerSharesOutsideCloudDocsTopLevel() {
        let dataSource = FileListDataSource()
        let cloudDocs = URL(fileURLWithPath: "/tmp/Mobile Documents/com~apple~CloudDocs")
        let ownerShare = makeEntry(
            url: URL(fileURLWithPath: "/tmp/Documents/2 Areas/Assistance/Finance/Tanja/Steuern Tanja"),
            isDirectory: true,
            isShared: true,
            role: .owner
        )

        let items = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: [],
            cloudDocsURL: cloudDocs,
            spotlightEntries: [ownerShare],
            showHidden: false
        )

        XCTAssertTrue(items.contains { $0.url.standardizedFileURL == ownerShare.url.standardizedFileURL })
        XCTAssertEqual(items.first(where: { $0.url.standardizedFileURL == ownerShare.url.standardizedFileURL })?.sharedLabelText, "Shared by me")
    }

    func testSharedModeDedupesSpotlightAgainstDatabaseViaSymlinkResolution() throws {
        let dataSource = FileListDataSource()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let cloudDocs = try createTestFolder(in: temp, name: "com~apple~CloudDocs")
        let documents = try createTestFolder(in: temp, name: "Documents")
        _ = try createTestFolder(in: documents, name: "Steuern Tanja")
        let cloudDocsDocumentsLink = cloudDocs.appendingPathComponent("Documents")
        try FileManager.default.createSymbolicLink(at: cloudDocsDocumentsLink, withDestinationURL: documents)

        let dbRecord = ICloudSharedRootRecord(
            relativePath: "Documents/Steuern Tanja",
            creatorID: 0,
            isDirectory: true
        )
        let spotlightOwnerShare = makeEntry(
            url: documents.appendingPathComponent("Steuern Tanja"),
            isDirectory: true,
            isShared: true,
            role: .owner
        )

        let items = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: [],
            cloudDocsURL: cloudDocs,
            sharedRootRecords: [dbRecord],
            spotlightEntries: [spotlightOwnerShare],
            showHidden: false
        )

        XCTAssertEqual(items.filter { $0.name == "Steuern Tanja" }.count, 1)
        let expectedURL = cloudDocs.appendingPathComponent("Documents/Steuern Tanja").standardizedFileURL
        XCTAssertEqual(items.first(where: { $0.name == "Steuern Tanja" })?.url.standardizedFileURL, expectedURL)
    }

    func testSharedModeRemapsSpotlightPathToCloudDocsSymlinkPath() throws {
        let dataSource = FileListDataSource()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let cloudDocs = try createTestFolder(in: temp, name: "com~apple~CloudDocs")
        let documents = try createTestFolder(in: temp, name: "Documents")
        _ = try createTestFolder(in: documents, name: "Steuern Tanja")
        let cloudDocsDocumentsLink = cloudDocs.appendingPathComponent("Documents")
        try FileManager.default.createSymbolicLink(at: cloudDocsDocumentsLink, withDestinationURL: documents)

        let spotlightOwnerShare = makeEntry(
            url: documents.appendingPathComponent("Steuern Tanja"),
            isDirectory: true,
            isShared: true,
            role: .owner
        )

        let items = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: [],
            cloudDocsURL: cloudDocs,
            spotlightEntries: [spotlightOwnerShare],
            showHidden: false
        )

        let expectedURL = cloudDocs.appendingPathComponent("Documents/Steuern Tanja").standardizedFileURL
        XCTAssertEqual(items.first?.url.standardizedFileURL, expectedURL)
    }

    func testSharedModeRemapsSpotlightPathUsingHiddenSymlinkAlias() throws {
        let dataSource = FileListDataSource()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let cloudDocs = try createTestFolder(in: temp, name: "com~apple~CloudDocs")
        let documents = try createTestFolder(in: temp, name: "Documents")
        _ = try createTestFolder(in: documents, name: "Steuern Tanja")
        let hiddenAlias = cloudDocs.appendingPathComponent(".Documents")
        try FileManager.default.createSymbolicLink(at: hiddenAlias, withDestinationURL: documents)

        let spotlightOwnerShare = makeEntry(
            url: documents.appendingPathComponent("Steuern Tanja"),
            isDirectory: true,
            isShared: true,
            role: .owner
        )

        let items = dataSource.composeICloudSharedTopLevelItems(
            cloudDocsChildren: [],
            cloudDocsURL: cloudDocs,
            spotlightEntries: [spotlightOwnerShare],
            showHidden: false
        )

        let expectedURL = hiddenAlias.appendingPathComponent("Steuern Tanja").standardizedFileURL
        XCTAssertEqual(items.first?.url.standardizedFileURL, expectedURL)
    }

    func testComposedListingEntriesPreserveVirtualAndSharedPresentationMetadata() throws {
        let dataSource = FileListDataSource()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let cloudDocs = try createTestFolder(in: temp, name: "com~apple~CloudDocs")
        let virtual = FileItem(
            name: "Shared",
            url: cloudDocs,
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: NSImage(),
            sharedRole: .owner,
            isVirtualSharedFolder: true,
            iCloudStatus: .downloaded
        )

        let rebuilt = dataSource.baseFileItems(for: [LoadedFileEntry(fileItem: virtual)])

        XCTAssertEqual(rebuilt.first?.sharedRole, .owner)
        XCTAssertTrue(rebuilt.first?.isVirtualSharedFolder == true)
        guard case .downloaded? = rebuilt.first?.iCloudStatus else {
            return XCTFail("Expected the composed iCloud status to survive scheduler transport")
        }
    }
}
