import XCTest
@testable import Detours

@MainActor
final class ArchivePasswordValidationTests: XCTestCase {
    func testZipPasswordByteLimit() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "secret.txt", content: "local secret")
        let eightyBytes = String(repeating: "a", count: 80)
        let eightyOneBytes = String(repeating: "a", count: 81)
        let multibyteEightyOneBytes = String(repeating: "a", count: 79) + "é"

        XCTAssertNoThrow(try ArchivePasswordValidation.validate(eightyBytes, format: .zip))
        XCTAssertEqual(
            ArchivePasswordValidation.errorMessage(for: eightyOneBytes, format: .zip),
            ArchivePasswordValidation.zipByteLimitMessage
        )
        XCTAssertEqual(
            ArchivePasswordValidation.errorMessage(for: multibyteEightyOneBytes, format: .zip),
            ArchivePasswordValidation.zipByteLimitMessage
        )
        XCTAssertNil(
            ArchivePasswordValidation.errorMessage(for: String(repeating: "z", count: 200), format: .sevenZ)
        )

        let model = ArchiveModel(sourceURLs: [source])
        model.format = .zip
        model.includePassword = true
        model.password = multibyteEightyOneBytes
        XCTAssertEqual(model.validationError, ArchivePasswordValidation.zipByteLimitMessage)

        do {
            _ = try await FileOperationQueue.shared.archive(
                items: [source],
                format: .zip,
                archiveName: "must-not-launch",
                password: eightyOneBytes
            )
            XCTFail("Expected local ZIP password preflight")
        } catch FileOperationError.archivePasswordInvalid(let message) {
            XCTAssertEqual(message, ArchivePasswordValidation.zipByteLimitMessage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("must-not-launch.zip").path))
    }
}
