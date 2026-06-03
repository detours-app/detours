import Foundation

struct ServerFolderSizeResult: Equatable, Sendable {
    let size: Int64?
    let isCalculating: Bool
}

actor FolderSizeOperations {
    private var cache: [String: Int64] = [:]
    private var stale: Set<String> = []
    private var pending: Set<String> = []

    func size(for path: String) -> ServerFolderSizeResult {
        let cached = cache[path]
        let needsRefresh = cached == nil || stale.contains(path)

        if needsRefresh, !pending.contains(path) {
            startRefresh(for: path)
        }

        return ServerFolderSizeResult(size: cached, isCalculating: needsRefresh)
    }

    func markStale(path: String) {
        if cache[path] != nil {
            stale.insert(path)
        } else {
            cache.removeValue(forKey: path)
        }
    }

    func store(size: Int64, for path: String) {
        cache[path] = size
        stale.remove(path)
        pending.remove(path)
    }

    private func startRefresh(for path: String) {
        pending.insert(path)
        Task.detached {
            let size = await Self.calculateFolderSize(at: path)
            await self.store(size: size, for: path)
        }
    }

    private static func calculateFolderSize(at path: String) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                process.arguments = ["-sb", path]

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: 0)
                        return
                    }

                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let size = output.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) } ?? 0
                    continuation.resume(returning: size)
                } catch {
                    continuation.resume(returning: 0)
                }
            }
        }
    }
}
