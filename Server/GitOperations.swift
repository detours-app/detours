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
        process.environment = ProcessInfo.processInfo.environment
            .merging(["GIT_CONFIG_NOSYSTEM": "1"]) { _, new in new }
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

        guard renamed.hasPrefix("\""), renamed.hasSuffix("\""), renamed.count >= 2 else {
            return renamed
        }
        return Self.unquoteCQuoted(String(renamed.dropFirst().dropLast()))
    }

    /// Decodes git's C-style quoting (octal \nnn escapes plus \\, \", \t, \n, \r) back into the real bytes.
    /// git --porcelain quotes any filename with non-ASCII or special characters when core.quotepath is on
    /// (the default), so stripping the surrounding quotes alone leaves literal escape sequences in the path.
    private static func unquoteCQuoted(_ value: String) -> String {
        let scalars = Array(value.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < scalars.count {
            let byte = scalars[index]
            guard byte == UInt8(ascii: "\\") else {
                bytes.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else {
                bytes.append(byte)
                break
            }
            let escape = scalars[index]
            index += 1
            switch escape {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "\\"): bytes.append(0x5C)
            case UInt8(ascii: "\""): bytes.append(0x22)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var octal = Int(escape - UInt8(ascii: "0"))
                var consumed = 0
                while consumed < 2, index < scalars.count,
                      scalars[index] >= UInt8(ascii: "0"), scalars[index] <= UInt8(ascii: "7") {
                    octal = octal * 8 + Int(scalars[index] - UInt8(ascii: "0"))
                    index += 1
                    consumed += 1
                }
                bytes.append(UInt8(octal & 0xFF))
            default:
                bytes.append(escape)
            }
        }
        // Git encodes quoted filenames as UTF-8 byte sequences; decode them byte-exact.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
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
