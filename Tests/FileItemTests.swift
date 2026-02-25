import AppKit
import XCTest
@testable import Detours

@MainActor
final class FileItemTests: XCTestCase {
    func testInitFromFile() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt", content: "hello")
        let item = FileItem(url: file)

        XCTAssertEqual(item.name, "a.txt")
        XCTAssertEqual(item.isDirectory, false)
        XCTAssertNotNil(item.size)
    }

    func testInitFromDirectory() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Folder")
        let item = FileItem(url: folder)

        XCTAssertEqual(item.isDirectory, true)
        XCTAssertNil(item.size)
    }

    func testSharedOwnerLabelIsSharedByMe() {
        let url = URL(fileURLWithPath: "/tmp/shared-owner")
        let item = FileItem(name: "shared-owner", url: url, isDirectory: false, size: 1, dateModified: Date(), icon: NSImage(), sharedRole: .owner)
        XCTAssertEqual(item.sharedLabelText, "Shared by me")
    }

    func testSharedParticipantLabelUsesOwnerName() {
        let url = URL(fileURLWithPath: "/tmp/shared-participant")
        let item = FileItem(name: "shared-participant", url: url, isDirectory: false, size: 1, dateModified: Date(), icon: NSImage(), sharedRole: .participant(ownerName: "Taylor"))
        XCTAssertEqual(item.sharedLabelText, "Shared by Taylor")
    }

    func testSharedOwnerLabelFromRoleWhenIsSharedFlagIsFalse() {
        let entry = LoadedFileEntry(
            url: URL(fileURLWithPath: "/tmp/shared-owner-role-only"),
            name: "shared-owner-role-only",
            isDirectory: true,
            ubiquitousItemIsShared: false,
            ubiquitousSharedItemCurrentUserRole: .owner
        )
        let item = FileItem(entry: entry, icon: NSImage())
        XCTAssertEqual(item.sharedLabelText, "Shared by me")
    }

    func testCloudDocsNotRenamedToShared() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let cloudDocs = try createTestFolder(in: temp, name: "com~apple~CloudDocs")
        let item = FileItem(url: cloudDocs)

        XCTAssertEqual(item.name, "com~apple~CloudDocs")
        XCTAssertNotEqual(item.name, "Shared")
    }

    func testFormattedSizeBytes() {
        let url = URL(fileURLWithPath: "/tmp/bytes")
        let item = FileItem(name: "bytes", url: url, isDirectory: false, size: 512, dateModified: Date(), icon: NSImage())
        XCTAssertEqual(item.formattedSize, "512 B")
    }

    func testFormattedSizeKB() {
        let url = URL(fileURLWithPath: "/tmp/kb")
        let item = FileItem(name: "kb", url: url, isDirectory: false, size: 1500, dateModified: Date(), icon: NSImage())
        XCTAssertEqual(item.formattedSize, "1.5 KB")
    }

    func testFormattedSizeMB() {
        let url = URL(fileURLWithPath: "/tmp/mb")
        let item = FileItem(name: "mb", url: url, isDirectory: false, size: 1_500_000, dateModified: Date(), icon: NSImage())
        XCTAssertEqual(item.formattedSize, "1.5 MB")
    }

    func testFormattedSizeGB() {
        let url = URL(fileURLWithPath: "/tmp/gb")
        let item = FileItem(name: "gb", url: url, isDirectory: false, size: 1_500_000_000, dateModified: Date(), icon: NSImage())
        XCTAssertEqual(item.formattedSize, "1.5 GB")
    }

    func testFormattedDateSameYear() {
        // Reset to default format
        SettingsManager.shared.dateFormatCurrentYear = "MMM d"

        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: calendar.component(.year, from: Date()), month: 1, day: 5))!
        let url = URL(fileURLWithPath: "/tmp/date")
        let item = FileItem(name: "date", url: url, isDirectory: false, size: 1, dateModified: date, icon: NSImage())

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        XCTAssertEqual(item.formattedDate, formatter.string(from: date))
    }

    func testFormattedDateDifferentYear() {
        // Reset to default format
        SettingsManager.shared.dateFormatOtherYears = "MMM d, yyyy"

        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2001, month: 12, day: 31))!
        let url = URL(fileURLWithPath: "/tmp/date")
        let item = FileItem(name: "date", url: url, isDirectory: false, size: 1, dateModified: date, icon: NSImage())

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        XCTAssertEqual(item.formattedDate, formatter.string(from: date))
    }

    func testFormattedDateUsesCurrentYearSetting() {
        // Set custom format
        SettingsManager.shared.dateFormatCurrentYear = "yyyy-MM-dd"

        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: calendar.component(.year, from: Date()), month: 3, day: 15))!
        let url = URL(fileURLWithPath: "/tmp/date")
        let item = FileItem(name: "date", url: url, isDirectory: false, size: 1, dateModified: date, icon: NSImage())

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(item.formattedDate, formatter.string(from: date))

        // Reset to default
        SettingsManager.shared.dateFormatCurrentYear = "MMM d"
    }

    func testFormattedDateUsesOtherYearsSetting() {
        // Set custom format
        SettingsManager.shared.dateFormatOtherYears = "dd/MM/yyyy"

        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2020, month: 6, day: 25))!
        let url = URL(fileURLWithPath: "/tmp/date")
        let item = FileItem(name: "date", url: url, isDirectory: false, size: 1, dateModified: date, icon: NSImage())

        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        XCTAssertEqual(item.formattedDate, formatter.string(from: date))

        // Reset to default
        SettingsManager.shared.dateFormatOtherYears = "MMM d, yyyy"
    }

    // MARK: - Sort Tests

    private func makeItem(name: String, isDirectory: Bool, size: Int64?, date: Date) -> FileItem {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return FileItem(name: name, url: url, isDirectory: isDirectory, size: size, dateModified: date, icon: NSImage())
    }

    func testSortByNameAscending() {
        let items = [
            makeItem(name: "Charlie.txt", isDirectory: false, size: 100, date: Date()),
            makeItem(name: "Alpha.txt", isDirectory: false, size: 200, date: Date()),
            makeItem(name: "Bravo.txt", isDirectory: false, size: 150, date: Date()),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .name, ascending: true), foldersOnTop: false)
        XCTAssertEqual(sorted.map(\.name), ["Alpha.txt", "Bravo.txt", "Charlie.txt"])
    }

    func testSortByNameDescending() {
        let items = [
            makeItem(name: "Alpha.txt", isDirectory: false, size: 100, date: Date()),
            makeItem(name: "Charlie.txt", isDirectory: false, size: 200, date: Date()),
            makeItem(name: "Bravo.txt", isDirectory: false, size: 150, date: Date()),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .name, ascending: false), foldersOnTop: false)
        XCTAssertEqual(sorted.map(\.name), ["Charlie.txt", "Bravo.txt", "Alpha.txt"])
    }

    func testSortBySizeAscending() {
        let items = [
            makeItem(name: "Big.txt", isDirectory: false, size: 1000, date: Date()),
            makeItem(name: "Small.txt", isDirectory: false, size: 10, date: Date()),
            makeItem(name: "Medium.txt", isDirectory: false, size: 500, date: Date()),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .size, ascending: true), foldersOnTop: false)
        XCTAssertEqual(sorted.map(\.name), ["Small.txt", "Medium.txt", "Big.txt"])
    }

    func testSortBySizeDescending() {
        let items = [
            makeItem(name: "Big.txt", isDirectory: false, size: 1000, date: Date()),
            makeItem(name: "Small.txt", isDirectory: false, size: 10, date: Date()),
            makeItem(name: "Medium.txt", isDirectory: false, size: 500, date: Date()),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .size, ascending: false), foldersOnTop: false)
        XCTAssertEqual(sorted.map(\.name), ["Big.txt", "Medium.txt", "Small.txt"])
    }

    func testSortByDateAscending() {
        let now = Date()
        let items = [
            makeItem(name: "Recent.txt", isDirectory: false, size: 100, date: now),
            makeItem(name: "Old.txt", isDirectory: false, size: 100, date: now.addingTimeInterval(-3600)),
            makeItem(name: "Middle.txt", isDirectory: false, size: 100, date: now.addingTimeInterval(-1800)),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .dateModified, ascending: true), foldersOnTop: false)
        XCTAssertEqual(sorted.map(\.name), ["Old.txt", "Middle.txt", "Recent.txt"])
    }

    func testSortByDateDescending() {
        let now = Date()
        let items = [
            makeItem(name: "Recent.txt", isDirectory: false, size: 100, date: now),
            makeItem(name: "Old.txt", isDirectory: false, size: 100, date: now.addingTimeInterval(-3600)),
            makeItem(name: "Middle.txt", isDirectory: false, size: 100, date: now.addingTimeInterval(-1800)),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .dateModified, ascending: false), foldersOnTop: false)
        XCTAssertEqual(sorted.map(\.name), ["Recent.txt", "Middle.txt", "Old.txt"])
    }

    func testSortFoldersOnTopByName() {
        let items = [
            makeItem(name: "Zeta.txt", isDirectory: false, size: 100, date: Date()),
            makeItem(name: "Beta", isDirectory: true, size: nil, date: Date()),
            makeItem(name: "Alpha.txt", isDirectory: false, size: 200, date: Date()),
            makeItem(name: "Delta", isDirectory: true, size: nil, date: Date()),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .name, ascending: true), foldersOnTop: true)
        XCTAssertEqual(sorted.map(\.name), ["Beta", "Delta", "Alpha.txt", "Zeta.txt"])
    }

    func testSortFoldersOnTopBySize() {
        let items = [
            makeItem(name: "Big.txt", isDirectory: false, size: 1000, date: Date()),
            makeItem(name: "FolderB", isDirectory: true, size: nil, date: Date()),
            makeItem(name: "Small.txt", isDirectory: false, size: 10, date: Date()),
            makeItem(name: "FolderA", isDirectory: true, size: nil, date: Date()),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .size, ascending: true), foldersOnTop: true)
        // Folders on top (sorted by size=0, tie-broken by name), then files by size
        XCTAssertEqual(sorted.map(\.name), ["FolderA", "FolderB", "Small.txt", "Big.txt"])
    }

    func testSortFoldersOnTopOff() {
        let items = [
            makeItem(name: "Zeta.txt", isDirectory: false, size: 100, date: Date()),
            makeItem(name: "Alpha", isDirectory: true, size: nil, date: Date()),
            makeItem(name: "Beta.txt", isDirectory: false, size: 200, date: Date()),
        ]
        let sorted = FileItem.sorted(items, by: SortDescriptor(column: .name, ascending: true), foldersOnTop: false)
        // All intermixed, sorted by name
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "Beta.txt", "Zeta.txt"])
    }

    func testSortPreservesChildrenUnderParent() {
        // Create a parent folder with children
        let parent = makeItem(name: "Parent", isDirectory: true, size: nil, date: Date())
        let childA = makeItem(name: "ChildA.txt", isDirectory: false, size: 500, date: Date())
        let childB = makeItem(name: "ChildB.txt", isDirectory: false, size: 100, date: Date())
        childA.parent = parent
        childB.parent = parent
        parent.children = [childA, childB]

        let otherFile = makeItem(name: "Other.txt", isDirectory: false, size: 200, date: Date())

        // Sort root items by size ascending with foldersOnTop
        let rootItems = [otherFile, parent]
        let sorted = FileItem.sorted(rootItems, by: SortDescriptor(column: .size, ascending: true), foldersOnTop: true)

        // Parent folder should still be first (foldersOnTop), and children array is unchanged
        XCTAssertEqual(sorted[0].name, "Parent")
        XCTAssertEqual(sorted[0].children?.map(\.name), ["ChildA.txt", "ChildB.txt"])
        XCTAssertEqual(sorted[1].name, "Other.txt")
    }
}
