import Foundation

func createTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory
    let url = base.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    return url
}

@discardableResult
func createTestFile(in directory: URL, name: String, content: String = "test") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.data(using: .utf8)?.write(to: url)
    return url
}

@discardableResult
func createTestFolder(in directory: URL, name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
    return url
}

func cleanupTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
