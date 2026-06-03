import Foundation

enum ServerGitStatus: String, Equatable, Sendable {
    case modified
    case staged
    case untracked
    case conflict
    case clean
}

struct ServerGitStatusEntry: Equatable, Sendable {
    let path: String
    let status: ServerGitStatus
}

struct GitOperations {
    func status(in directory: String) throws -> [ServerGitStatusEntry] {
        guard isGitRepository(directory) else { return [] }

        let output = try runGit(arguments: ["status", "--porcelain", "-uall"], in: directory)
        let gitRoot = try? runGit(arguments: ["rev-parse", "--show-toplevel"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return parsePorcelain(output, gitRoot: gitRoot?.isEmpty == false ? gitRoot! : directory)
    }

    func parsePorcelain(_ output: String, gitRoot: String) -> [ServerGitStatusEntry] {
        output.components(separatedBy: "\n").compactMap { line in
            guard line.count >= 3 else { return nil }

            let index = line[line.startIndex]
            let workTree = line[line.index(after: line.startIndex)]
            let filename = normalizeFilename(String(line.dropFirst(3)))
            let status = determineStatus(index: index, workTree: workTree)

            guard status != .clean else { return nil }

            let path = URL(fileURLWithPath: gitRoot).appendingPathComponent(filename).path
            return ServerGitStatusEntry(path: path, status: status)
        }
    }

    private func isGitRepository(_ directory: String) -> Bool {
        (try? runGit(arguments: ["rev-parse", "--is-inside-work-tree"], in: directory)) != nil
    }

    private func runGit(arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false"] + arguments
        process.environment = ["GIT_CONFIG_NOSYSTEM": "1"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ServerRPCError.unsupportedCommand("git \(arguments.joined(separator: " "))")
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func normalizeFilename(_ filename: String) -> String {
        let renamed: String
        if let arrowRange = filename.range(of: " -> ") {
            renamed = String(filename[arrowRange.upperBound...])
        } else {
            renamed = filename
        }

        if renamed.hasPrefix("\""), renamed.hasSuffix("\"") {
            return String(renamed.dropFirst().dropLast())
        }
        return renamed
    }

    private func determineStatus(index: Character, workTree: Character) -> ServerGitStatus {
        if index == "?", workTree == "?" {
            return .untracked
        }

        if index == "U" || workTree == "U" ||
            (index == "A" && workTree == "A") ||
            (index == "D" && workTree == "D") {
            return .conflict
        }

        if index != " ", index != "?" {
            return workTree == " " ? .staged : .modified
        }

        if workTree == "M" || workTree == "D" {
            return .modified
        }

        return .clean
    }
}
