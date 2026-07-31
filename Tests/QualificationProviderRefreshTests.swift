import Foundation
import QualificationSupport
import XCTest
@testable import Detours

@MainActor
final class QualificationProviderRefreshTests: XCTestCase {
    func testMountedProviderRefreshContracts() async throws {
        let roots = try ["LOCAL_ROOT", "APFS_ROOT", "ICLOUD_ROOT", "SMB_ROOT"].map { key in
            // Only the qualification runner mounts these roots and exports them. A bare
            // `swift test` has no such fixtures, so this is out of scope for that run
            // rather than a failure of the contract under test.
            guard let value = ProcessInfo.processInfo.environment[key] else {
                throw XCTSkip("\(key) is exported by the qualification runner; run this through resources/scripts/qualification-foundry.sh")
            }
            return URL(fileURLWithPath: value, isDirectory: true)
        }

        for (index, root) in roots.enumerated() {
            let scenario = try makeScenario(index: index, root: root)
            do {
                try await assertRefreshContract(at: scenario)
            } catch {
                validatedCleanup(scenario)
                throw error
            }
            validatedCleanup(scenario)
        }
    }

    private func assertRefreshContract(at scenario: URL) async throws {
        let provider = LocalFileProvider.shared
        let location = Location.local(scenario)
        let initialListing = try await provider.list(location, showHidden: true)
        XCTAssertTrue(initialListing.isEmpty)

        let changeReceived = expectation(description: "provider change for \(scenario.path)")
        let changeLatch = OneShotExpectation(changeReceived)
        let watch = try await provider.watch(location) { _ in
            changeLatch.fulfill()
        }
        do {
            let created = scenario.appendingPathComponent("created.txt")
            try Data("created".utf8).write(to: created)
            await fulfillment(of: [changeReceived], timeout: 5)

            let createdListing = try await provider.list(location, showHidden: true)
            let createdEntry = try XCTUnwrap(createdListing.first { $0.name == "created.txt" })
            XCTAssertEqual(createdEntry.fileSize, 7)
            let stableListing = try await provider.list(location, showHidden: true)
            XCTAssertEqual(snapshot(createdListing), snapshot(stableListing))

            let renamed = try await provider.rename(.local(created), to: "renamed.txt")
            let renamedListing = try await provider.list(location, showHidden: true)
            XCTAssertEqual(renamed, .local(scenario.appendingPathComponent("renamed.txt")))
            XCTAssertEqual(renamedListing.map(\.name), ["renamed.txt"])

            try FileManager.default.removeItem(at: renamed.url)
            let finalListing = try await provider.list(location, showHidden: true)
            XCTAssertTrue(finalListing.isEmpty)
        } catch {
            await provider.unwatch(watch)
            throw error
        }
        await provider.unwatch(watch)
    }

    private func makeScenario(index: Int, root: URL) throws -> URL {
        let scenario = root.appendingPathComponent("provider-refresh-\(index)", isDirectory: true)
        try validate(scenario, under: root)
        try FileManager.default.createDirectory(at: scenario, withIntermediateDirectories: false)
        return scenario
    }

    private func validatedCleanup(_ scenario: URL) {
        do {
            try validate(scenario, under: scenario.deletingLastPathComponent())
            try FileManager.default.removeItem(at: scenario)
        } catch {
            XCTFail("Guarded provider cleanup failed: \(error)")
        }
    }

    private func validate(_ candidate: URL, under root: URL) throws {
        let sentinel = root.appendingPathComponent(QualificationRunRootDescriptor.sentinelFileName)
        let descriptor = try QualificationRunRootGuard().readDescriptor(at: sentinel)
        try QualificationRunRootGuard().validate(descriptor: descriptor, candidate: candidate)
    }

    private func snapshot(_ entries: [LoadedFileEntry]) -> [String] {
        entries.map { entry in
            [
                entry.name,
                String(entry.isDirectory),
                String(describing: entry.fileSize),
                String(entry.contentModificationDate.timeIntervalSince1970),
            ].joined(separator: "|")
        }.sorted()
    }
}

private final class OneShotExpectation: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var isFulfilled = false

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFulfilled else { return }
        isFulfilled = true
        expectation.fulfill()
    }
}
