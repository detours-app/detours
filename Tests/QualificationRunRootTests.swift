import Foundation
import QualificationSupport
import XCTest

final class QualificationRunRootTests: XCTestCase {
    func testEveryProviderCreatesValidatesAndRemovesOnlyItsMarkedRoot() throws {
        for provider in QualificationProvider.allCases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let descriptor = try fixture.guardService.create(
                provider: provider,
                allowlistedParent: fixture.parent
            )
            let child = URL(fileURLWithPath: descriptor.rootPath).appendingPathComponent("future.txt")

            try fixture.guardService.validate(descriptor: descriptor, candidate: child)
            try fixture.guardService.removeValidatedRoot(descriptor)

            XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.rootPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.outside.path))
        }
    }

    func testRejectsParentTraversalAndCleanupOutsideAllowlist() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try fixture.guardService.create(provider: .local, allowlistedParent: fixture.parent)
        let root = URL(fileURLWithPath: descriptor.rootPath)
        let traversal = root.appendingPathComponent("../outside.txt")
        let forged = QualificationRunRootDescriptor(
            provider: .local,
            identifier: descriptor.identifier,
            parentPath: fixture.parent.path,
            rootPath: fixture.outside.path,
            volumeIdentifier: descriptor.volumeIdentifier
        )

        XCTAssertThrowsError(try fixture.guardService.validate(descriptor: descriptor, candidate: traversal))
        XCTAssertThrowsError(try fixture.guardService.removeValidatedRoot(forged))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.outside.path))
    }

    func testRejectsSymbolicLinkAndFinderAliasComponents() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try fixture.guardService.create(provider: .local, allowlistedParent: fixture.parent)
        let root = URL(fileURLWithPath: descriptor.rootPath)
        let link = root.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside)
        XCTAssertThrowsError(try fixture.guardService.validate(descriptor: descriptor, candidate: link)) {
            XCTAssertEqual($0 as? QualificationRunRootError, .symbolicLink(link.path))
        }

        let alias = root.appendingPathComponent("escape-alias")
        let bookmark = try fixture.outside.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: alias)
        XCTAssertThrowsError(try fixture.guardService.validate(descriptor: descriptor, candidate: alias)) {
            XCTAssertEqual($0 as? QualificationRunRootError, .finderAlias(alias.path))
        }
    }

    func testRejectsAbsentAndMismatchedSentinels() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try fixture.guardService.create(provider: .local, allowlistedParent: fixture.parent)
        let sentinel = URL(fileURLWithPath: descriptor.sentinelPath)
        try FileManager.default.removeItem(at: sentinel)
        XCTAssertThrowsError(try fixture.guardService.validate(
            descriptor: descriptor,
            candidate: URL(fileURLWithPath: descriptor.rootPath)
        )) {
            XCTAssertEqual($0 as? QualificationRunRootError, .missingSentinel(sentinel.path))
        }

        try Data("{}".utf8).write(to: sentinel)
        XCTAssertThrowsError(try fixture.guardService.validate(
            descriptor: descriptor,
            candidate: URL(fileURLWithPath: descriptor.rootPath)
        )) {
            XCTAssertEqual($0 as? QualificationRunRootError, .sentinelMismatch(sentinel.path))
        }
    }

    func testRejectsRenamedRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try fixture.guardService.create(provider: .local, allowlistedParent: fixture.parent)
        let root = URL(fileURLWithPath: descriptor.rootPath)
        let renamed = fixture.parent.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.moveItem(at: root, to: renamed)

        XCTAssertThrowsError(try fixture.guardService.validate(descriptor: descriptor, candidate: root)) {
            XCTAssertEqual(
                $0 as? QualificationRunRootError,
                .rootWasRenamed(expected: root.path, actual: "missing")
            )
        }
    }

    func testRejectsStaleMountIdentity() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try fixture.guardService.create(provider: .apfs, allowlistedParent: fixture.parent)
        let stale = QualificationRunRootDescriptor(
            provider: descriptor.provider,
            identifier: descriptor.identifier,
            parentPath: descriptor.parentPath,
            rootPath: descriptor.rootPath,
            volumeIdentifier: descriptor.volumeIdentifier &+ 1,
            createdAt: descriptor.createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stale).write(to: URL(fileURLWithPath: stale.sentinelPath))

        XCTAssertThrowsError(try fixture.guardService.validate(
            descriptor: stale,
            candidate: URL(fileURLWithPath: stale.rootPath)
        )) {
            XCTAssertEqual(
                $0 as? QualificationRunRootError,
                .staleMount(expected: stale.volumeIdentifier, actual: descriptor.volumeIdentifier)
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("detours-qualification-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let outside = parent.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        return Fixture(parent: parent, outside: outside)
    }
}

private struct Fixture {
    let parent: URL
    let outside: URL
    let guardService = QualificationRunRootGuard()

    func cleanup() {
        try? FileManager.default.removeItem(at: parent)
    }
}
