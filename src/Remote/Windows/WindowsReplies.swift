import Foundation

struct WindowsDirectoryEntry: Decodable, Equatable, Sendable {
    let name: String
    let nativePath: String
    let isDirectory: Bool
    let isHidden: Bool
    let isReparsePoint: Bool
    let byteCount: Int64?
    let modificationDate: Date

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case nativePath = "FullName"
        case psIsContainer = "PSIsContainer"
        case attributes = "Attributes"
        case length = "Length"
        case lastWriteTime = "LastWriteTime"
        case lastWriteTimeUtc = "LastWriteTimeUtc"
    }

    init(
        name: String,
        nativePath: String,
        isDirectory: Bool,
        isHidden: Bool = false,
        isReparsePoint: Bool = false,
        byteCount: Int64? = nil,
        modificationDate: Date
    ) {
        self.name = name
        self.nativePath = nativePath
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isReparsePoint = isReparsePoint
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        nativePath = try container.decode(String.self, forKey: .nativePath)
        isDirectory = try container.decode(Bool.self, forKey: .psIsContainer)
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .length)

        let attributes = try container.decodeIfPresent(String.self, forKey: .attributes) ?? ""
        isHidden = attributes.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "Hidden" }
        isReparsePoint = attributes.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces) == "ReparsePoint"
        }

        if let date = try container.decodePowerShellDateIfPresent(forKey: .lastWriteTimeUtc)
            ?? container.decodePowerShellDateIfPresent(forKey: .lastWriteTime) {
            modificationDate = date
        } else {
            modificationDate = .distantPast
        }
    }
}

struct WindowsDriveEntry: Decodable, Equatable, Sendable {
    let name: String
    let nativeRoot: String
    let freeBytes: Int64?
    let usedBytes: Int64?

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case root = "Root"
        case free = "Free"
        case used = "Used"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        nativeRoot = try container.decodeIfPresent(String.self, forKey: .root) ?? "\(name):\\"
        freeBytes = try container.decodeIfPresent(Int64.self, forKey: .free)
        usedBytes = try container.decodeIfPresent(Int64.self, forKey: .used)
    }
}

struct WindowsErrorEnvelope: Decodable, Equatable, Sendable {
    let message: String
    let category: String?
    let fullyQualifiedErrorID: String?

    private enum CodingKeys: String, CodingKey {
        case message = "Message"
        case category = "Category"
        case fullyQualifiedErrorID = "FullyQualifiedErrorId"
    }
}

enum WindowsReplyDecoder {
    static func decodeArrayOrSingle<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        let decoder = JSONDecoder.detoursWindows
        // PowerShell's ConvertTo-Json emits an array, a single object, or the bare
        // literal `null`. Dispatch on the first significant byte so the payload is
        // parsed exactly once rather than being speculatively decoded up to three times.
        let isWhitespace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        guard let firstByte = data.first(where: { !isWhitespace($0) }) else {
            return [try decoder.decode(T.self, from: data)]
        }
        switch firstByte {
        case UInt8(ascii: "["):
            return try decoder.decode([T].self, from: data)
        case UInt8(ascii: "n"):
            // Only the exact literal `null` means an empty result. Any other
            // `n`-prefixed payload (e.g. `nan`, a truncated `nul`) is malformed and
            // must surface a decode error rather than being silently dropped.
            let significant = data.filter { !isWhitespace($0) }
            guard significant.elementsEqual("null".utf8) else {
                return [try decoder.decode(T.self, from: data)]
            }
            return []
        default:
            return [try decoder.decode(T.self, from: data)]
        }
    }
}

private extension KeyedDecodingContainer {
    func decodePowerShellDateIfPresent(forKey key: Key) throws -> Date? {
        if let milliseconds = try? decode(Int64.self, forKey: key) {
            return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        }
        if let string = try? decode(String.self, forKey: key) {
            if let date = Self.iso8601Date(string) {
                return date
            }
            if let date = Self.powerShellJSONDate(string) {
                return date
            }
        }
        return nil
    }

    static func powerShellJSONDate(_ value: String) -> Date? {
        guard value.hasPrefix("/Date("), value.hasSuffix(")/") else { return nil }
        let body = value.dropFirst(6).dropLast(2)
        let millisecondsText = body.prefix { $0 == "-" || $0.isNumber }
        guard let milliseconds = Int64(millisecondsText) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    static func iso8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
