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
        if case .some(.none) = try? decoder.decode(Optional<T>.self, from: data) {
            return []
        }
        if let array = try? decoder.decode([T].self, from: data) {
            return array
        }
        return [try decoder.decode(T.self, from: data)]
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
