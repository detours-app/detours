import Foundation

public enum QualificationProvider: String, Codable, CaseIterable, Sendable {
    case local
    case apfs
    case iCloud
    case smb
    case linux
    case intelMac
    case windows
}

public struct QualificationRunRootDescriptor: Codable, Equatable, Sendable {
    public static let sentinelFileName = ".detours-qualification-root.json"

    public let provider: QualificationProvider
    public let identifier: UUID
    public let parentPath: String
    public let rootPath: String
    public let createdAt: Date

    public init(
        provider: QualificationProvider,
        identifier: UUID,
        parentPath: String,
        rootPath: String,
        createdAt: Date = Date()
    ) {
        self.provider = provider
        self.identifier = identifier
        self.parentPath = parentPath
        self.rootPath = rootPath
        self.createdAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
    }

    public var sentinelPath: String {
        URL(fileURLWithPath: rootPath)
            .appendingPathComponent(Self.sentinelFileName, isDirectory: false)
            .path
    }
}

public struct QualificationSnapshotEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    public let kind: String
    public let byteCount: Int64?
    public let modificationNanoseconds: Int64?
    public let contentDigest: String?

    public init(
        relativePath: String,
        kind: String,
        byteCount: Int64?,
        modificationNanoseconds: Int64?,
        contentDigest: String?
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.byteCount = byteCount
        self.modificationNanoseconds = modificationNanoseconds
        self.contentDigest = contentDigest
    }
}

public struct QualificationOutsideRootSnapshot: Codable, Equatable, Sendable {
    public let provider: QualificationProvider
    public let parentPath: String
    public let excludedRootPath: String
    public let capturedAt: Date
    public let entries: [QualificationSnapshotEntry]

    public init(
        provider: QualificationProvider,
        parentPath: String,
        excludedRootPath: String,
        capturedAt: Date = Date(),
        entries: [QualificationSnapshotEntry]
    ) {
        self.provider = provider
        self.parentPath = parentPath
        self.excludedRootPath = excludedRootPath
        self.capturedAt = capturedAt
        self.entries = entries
    }
}

public enum QualificationRunRootError: LocalizedError, Equatable {
    case parentMissing(String)
    case parentNotDirectory(String)
    case invalidIdentifier(String)
    case rootAlreadyExists(String)
    case rootIsNotExactChild(parent: String, root: String)
    case pathOutsideRoot(root: String, candidate: String)
    case symbolicLink(String)
    case finderAlias(String)
    case missingSentinel(String)
    case sentinelMismatch(String)
    case rootWasRenamed(expected: String, actual: String)
    case descriptorDecode(String)
    case unsupportedProvider(String)

    public var errorDescription: String? {
        switch self {
        case .parentMissing(let path): "Allowlisted parent does not exist: \(path)"
        case .parentNotDirectory(let path): "Allowlisted parent is not a directory: \(path)"
        case .invalidIdentifier(let value): "Run-root name is not a lowercase UUID: \(value)"
        case .rootAlreadyExists(let path): "Run root already exists: \(path)"
        case .rootIsNotExactChild(let parent, let root): "Run root is not an exact child of \(parent): \(root)"
        case .pathOutsideRoot(let root, let candidate): "Candidate escapes run root \(root): \(candidate)"
        case .symbolicLink(let path): "Symbolic-link component is forbidden: \(path)"
        case .finderAlias(let path): "Finder-alias component is forbidden: \(path)"
        case .missingSentinel(let path): "Run-root sentinel is missing: \(path)"
        case .sentinelMismatch(let path): "Run-root sentinel does not match its descriptor: \(path)"
        case .rootWasRenamed(let expected, let actual): "Run root was renamed from \(expected) to \(actual)"
        case .descriptorDecode(let message): "Run-root descriptor could not be decoded: \(message)"
        case .unsupportedProvider(let provider): "Provider is unsupported: \(provider)"
        }
    }
}

public struct QualificationRunRootGuard {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func create(provider: QualificationProvider, allowlistedParent: URL, identifier: UUID = UUID()) throws -> QualificationRunRootDescriptor {
        let parent = lexicallyStandardized(allowlistedParent)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) else {
            throw QualificationRunRootError.parentMissing(parent.path)
        }
        guard isDirectory.boolValue else {
            throw QualificationRunRootError.parentNotDirectory(parent.path)
        }
        try rejectLinksAndAliases(inExistingComponentsOf: parent)

        let canonicalParent = lexicallyStandardized(parent.resolvingSymlinksInPath())
        let root = canonicalParent.appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: true)
        try validateExactChild(parent: canonicalParent, root: root, identifier: identifier)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw QualificationRunRootError.rootAlreadyExists(root.path)
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let descriptor = QualificationRunRootDescriptor(
            provider: provider,
            identifier: identifier,
            parentPath: canonicalParent.path,
            rootPath: root.path
        )
        do {
            try encoder.encode(descriptor).write(
                to: root.appendingPathComponent(QualificationRunRootDescriptor.sentinelFileName),
                options: [.atomic]
            )
            try validate(descriptor: descriptor, candidate: root)
            return descriptor
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    public func validate(descriptor: QualificationRunRootDescriptor, candidate: URL) throws {
        guard descriptor.rootPath == lexicallyStandardized(URL(fileURLWithPath: descriptor.rootPath)).path else {
            throw QualificationRunRootError.rootWasRenamed(
                expected: descriptor.rootPath,
                actual: lexicallyStandardized(URL(fileURLWithPath: descriptor.rootPath)).path
            )
        }
        let parent = lexicallyStandardized(URL(fileURLWithPath: descriptor.parentPath))
        let root = lexicallyStandardized(URL(fileURLWithPath: descriptor.rootPath))
        try validateExactChild(parent: parent, root: root, identifier: descriptor.identifier)
        try rejectLinksAndAliases(inExistingComponentsOf: root)
        try validateSentinel(for: descriptor)

        let standardizedCandidate = lexicallyStandardized(candidate)
        guard isContained(standardizedCandidate, by: root) else {
            throw QualificationRunRootError.pathOutsideRoot(root: root.path, candidate: standardizedCandidate.path)
        }
        try rejectLinksAndAliases(inExistingComponentsOf: standardizedCandidate)

        let resolvedRoot = lexicallyStandardized(root.resolvingSymlinksInPath())
        let resolvedCandidate = deepestExistingAncestor(of: standardizedCandidate)
            .resolvingSymlinksInPath()
        let lexicalResolvedCandidate = lexicallyStandardized(resolvedCandidate)
        guard isContained(lexicalResolvedCandidate, by: resolvedRoot) else {
            throw QualificationRunRootError.pathOutsideRoot(root: resolvedRoot.path, candidate: lexicalResolvedCandidate.path)
        }
    }

    public func readDescriptor(at url: URL) throws -> QualificationRunRootDescriptor {
        do {
            let descriptor = try decoder.decode(QualificationRunRootDescriptor.self, from: Data(contentsOf: url))
            try validate(descriptor: descriptor, candidate: URL(fileURLWithPath: descriptor.rootPath))
            return descriptor
        } catch let error as QualificationRunRootError {
            throw error
        } catch {
            throw QualificationRunRootError.descriptorDecode(error.localizedDescription)
        }
    }

    public func writeDescriptor(_ descriptor: QualificationRunRootDescriptor, to url: URL) throws {
        try validate(descriptor: descriptor, candidate: URL(fileURLWithPath: descriptor.rootPath))
        try encoder.encode(descriptor).write(to: url, options: [.atomic])
    }

    public func removeValidatedRoot(_ descriptor: QualificationRunRootDescriptor) throws {
        let root = URL(fileURLWithPath: descriptor.rootPath)
        try validate(descriptor: descriptor, candidate: root)
        try fileManager.removeItem(at: root)
    }

    private func validateExactChild(parent: URL, root: URL, identifier: UUID) throws {
        let expectedName = identifier.uuidString.lowercased()
        guard root.lastPathComponent == expectedName,
              lexicallyStandardized(root.deletingLastPathComponent()).path == lexicallyStandardized(parent).path else {
            throw QualificationRunRootError.rootIsNotExactChild(parent: parent.path, root: root.path)
        }
        guard UUID(uuidString: root.lastPathComponent)?.uuidString.lowercased() == root.lastPathComponent else {
            throw QualificationRunRootError.invalidIdentifier(root.lastPathComponent)
        }
    }

    private func validateSentinel(for descriptor: QualificationRunRootDescriptor) throws {
        let sentinelURL = URL(fileURLWithPath: descriptor.sentinelPath)
        guard fileManager.fileExists(atPath: sentinelURL.path) else {
            throw QualificationRunRootError.missingSentinel(sentinelURL.path)
        }
        let decoded: QualificationRunRootDescriptor
        do {
            decoded = try decoder.decode(QualificationRunRootDescriptor.self, from: Data(contentsOf: sentinelURL))
        } catch {
            throw QualificationRunRootError.sentinelMismatch(sentinelURL.path)
        }
        guard decoded == descriptor else {
            throw QualificationRunRootError.sentinelMismatch(sentinelURL.path)
        }
    }

    private func rejectLinksAndAliases(inExistingComponentsOf url: URL) throws {
        let standardized = lexicallyStandardized(url)
        let components = standardized.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            guard fileManager.fileExists(atPath: current.path) else { break }
            let attributes = try fileManager.attributesOfItem(atPath: current.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw QualificationRunRootError.symbolicLink(current.path)
            }
            let values = try current.resourceValues(forKeys: [.isAliasFileKey])
            if values.isAliasFile == true {
                throw QualificationRunRootError.finderAlias(current.path)
            }
        }
    }

    private func deepestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while !fileManager.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private func isContained(_ candidate: URL, by root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private func lexicallyStandardized(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.pathComponents {
            switch component {
            case "/", ".", "":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return components.reduce(URL(fileURLWithPath: "/", isDirectory: true)) { partial, component in
            partial.appendingPathComponent(component)
        }
    }
}
