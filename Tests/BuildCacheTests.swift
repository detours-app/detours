import Foundation
import XCTest

final class BuildCacheTests: XCTestCase {
    func testHashTriggersRebuildWhenSourceChanges() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serverProbe = root
            .appendingPathComponent("Server", isDirectory: true)
            .appendingPathComponent(".build-cache-test-\(UUID().uuidString).swift")
        let unrelatedProbe = root
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent(".build-cache-test-\(UUID().uuidString).swift")
        defer {
            try? FileManager.default.removeItem(at: serverProbe)
            try? FileManager.default.removeItem(at: unrelatedProbe)
        }

        let initialHash = try serverCacheHash()

        try "let serverCacheProbe = 1\n".write(to: serverProbe, atomically: true, encoding: .utf8)
        let changedServerHash = try serverCacheHash()
        XCTAssertNotEqual(initialHash, changedServerHash)

        try FileManager.default.removeItem(at: serverProbe)
        let restoredHash = try serverCacheHash()
        XCTAssertEqual(initialHash, restoredHash)

        try "let unrelatedCacheProbe = 1\n".write(to: unrelatedProbe, atomically: true, encoding: .utf8)
        let unrelatedHash = try serverCacheHash()
        XCTAssertEqual(initialHash, unrelatedHash)
    }

    private func serverCacheHash() throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["resources/scripts/server-cache-hash.sh"]
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
