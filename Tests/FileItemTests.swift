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

    func testSortFoldersFirst() {
        let folderURL = URL(fileURLWithPath: "/tmp/folder")
        let fileURL = URL(fileURLWithPath: "/tmp/file.txt")
        let folder = FileItem(name: "Folder", url: folderURL, isDirectory: true, size: nil, dateModified: Date(), icon: NSImage())
        let file = FileItem(name: "File.txt", url: fileURL, isDirectory: false, size: 1, dateModified: Date(), icon: NSImage())

        let sorted = FileItem.sortFoldersFirst([file, folder])
        XCTAssertEqual(sorted.first?.isDirectory, true)
    }
}
