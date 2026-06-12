import Foundation

#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

enum ServerWatchEventKind: UInt8, Equatable, Sendable {
    case created = 1
    case modified = 2
    case deleted = 3
    case renamed = 4
}

struct ServerWatchEvent: Equatable, Sendable {
    let token: UUID
    let kind: ServerWatchEventKind
    let path: String
}

struct InotifyDescriptorEvent: Equatable, Sendable {
    let descriptor: Int32
    let kind: ServerWatchEventKind
    let name: String
}

enum ServerWatcherError: Error, Equatable, Sendable {
    case unsupportedPlatform
    case inotifyLimitExceeded(command: String)
    case systemCallFailed(String, errno: Int32)
    case unknownWatch(UUID)
}

protocol InotifyBackend {
    func addWatch(path: String) throws -> Int32
    func removeWatch(_ descriptor: Int32) throws
    func readEvents() throws -> [InotifyDescriptorEvent]
}

final class Watcher: @unchecked Sendable {
    static let inotifyLimitCommand = "sudo sysctl fs.inotify.max_user_watches=524288"

    private let backend: InotifyBackend
    private let lock = NSLock()
    private var watchesByToken: [UUID: WatchRegistration] = [:]
    private var tokenByDescriptor: [Int32: UUID] = [:]

    #if os(Linux) || os(macOS)
    init(backend: InotifyBackend = SystemInotifyBackend()) {
        self.backend = backend
    }
    #else
    init(backend: InotifyBackend = UnsupportedInotifyBackend()) {
        self.backend = backend
    }
    #endif

    var visibleWatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return watchesByToken.count
    }

    func watchVisibleDirectory(_ path: String, token: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        if watchesByToken[token] != nil {
            let registration = watchesByToken.removeValue(forKey: token)
            if let registration {
                tokenByDescriptor.removeValue(forKey: registration.descriptor)
                try backend.removeWatch(registration.descriptor)
            }
        }

        do {
            let descriptor = try backend.addWatch(path: path)
            watchesByToken[token] = WatchRegistration(token: token, path: path, descriptor: descriptor)
            tokenByDescriptor[descriptor] = token
        } catch ServerWatcherError.systemCallFailed("inotify_add_watch", let errno) where errno == ENOSPC {
            throw ServerWatcherError.inotifyLimitExceeded(command: Self.inotifyLimitCommand)
        }
    }

    func unwatch(_ token: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let registration = watchesByToken.removeValue(forKey: token) else {
            throw ServerWatcherError.unknownWatch(token)
        }
        tokenByDescriptor.removeValue(forKey: registration.descriptor)
        try backend.removeWatch(registration.descriptor)
    }

    func registration(for token: UUID) -> WatchRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return watchesByToken[token]
    }

    func token(for descriptor: Int32) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return tokenByDescriptor[descriptor]
    }

    func event(forDescriptor descriptor: Int32, kind: ServerWatchEventKind, name: String) -> ServerWatchEvent? {
        lock.lock()
        defer { lock.unlock() }
        return eventLocked(forDescriptor: descriptor, kind: kind, name: name)
    }

    func pendingEvents() throws -> [ServerWatchEvent] {
        let descriptorEvents = try backend.readEvents()
        lock.lock()
        defer { lock.unlock() }
        return descriptorEvents.compactMap { event in
            eventLocked(forDescriptor: event.descriptor, kind: event.kind, name: event.name)
        }
    }

    private func eventLocked(forDescriptor descriptor: Int32, kind: ServerWatchEventKind, name: String) -> ServerWatchEvent? {
        guard let token = tokenByDescriptor[descriptor],
              let registration = watchesByToken[token] else {
            return nil
        }

        let eventPath: String
        if name.isEmpty {
            eventPath = registration.path
        } else {
            eventPath = URL(fileURLWithPath: registration.path).appendingPathComponent(name).path
        }

        return ServerWatchEvent(token: token, kind: kind, path: eventPath)
    }

    func reemitWatchAfterDirectoryRename(token: UUID, newPath: String) throws -> ServerWatchEvent {
        lock.lock()
        defer { lock.unlock() }
        guard var registration = watchesByToken[token] else {
            throw ServerWatcherError.unknownWatch(token)
        }
        registration.path = newPath
        watchesByToken[token] = registration
        return ServerWatchEvent(token: token, kind: .renamed, path: newPath)
    }
}

struct WatchRegistration: Equatable, Sendable {
    let token: UUID
    var path: String
    let descriptor: Int32
}

final class SystemInotifyBackend: InotifyBackend {
    #if os(macOS)
    private final class DarwinWatch: @unchecked Sendable {
        let descriptor: Int32
        let fileDescriptor: Int32
        let source: DispatchSourceFileSystemObject

        init(descriptor: Int32, fileDescriptor: Int32, source: DispatchSourceFileSystemObject) {
            self.descriptor = descriptor
            self.fileDescriptor = fileDescriptor
            self.source = source
        }

        deinit {
            source.cancel()
        }
    }
    #endif

    private final class FileDescriptor {
        let rawValue: Int32

        init() throws {
            #if os(Linux)
            let flags = Int32(IN_CLOEXEC | IN_NONBLOCK)
            rawValue = inotify_init1(flags)
            guard rawValue >= 0 else {
                throw ServerWatcherError.systemCallFailed("inotify_init1", errno: errno)
            }
            #else
            throw ServerWatcherError.unsupportedPlatform
            #endif
        }

        deinit {
            #if os(Linux)
            close(rawValue)
            #endif
        }
    }

    #if os(macOS)
    private let lock = NSLock()
    private var nextDescriptor: Int32 = 1
    private var watches: [Int32: DarwinWatch] = [:]
    private var pending: [InotifyDescriptorEvent] = []

    init() {}
    #else
    private let descriptorLock = NSLock()
    private var createdDescriptor: FileDescriptor?

    init() {}

    private func inotifyDescriptor() throws -> FileDescriptor {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        if let createdDescriptor {
            return createdDescriptor
        }
        let descriptor = try FileDescriptor()
        createdDescriptor = descriptor
        return descriptor
    }
    #endif

    func addWatch(path: String) throws -> Int32 {
        #if os(Linux)
        let mask = UInt32(IN_CREATE | IN_MODIFY | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB)
        let inotifyFD = try inotifyDescriptor().rawValue
        let watchDescriptor = path.withCString { pathPointer in
            inotify_add_watch(inotifyFD, pathPointer, mask)
        }
        guard watchDescriptor >= 0 else {
            throw ServerWatcherError.systemCallFailed("inotify_add_watch", errno: errno)
        }
        return watchDescriptor
        #elseif os(macOS)
        let fileDescriptor = Darwin.open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            throw ServerWatcherError.systemCallFailed("open", errno: errno)
        }

        lock.lock()
        let watchDescriptor = nextDescriptor
        nextDescriptor += 1
        lock.unlock()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            let kind: ServerWatchEventKind
            if data.contains(.rename) {
                kind = .renamed
            } else if data.contains(.delete) {
                kind = .deleted
            } else if data.contains(.write) {
                kind = .created
            } else {
                kind = .modified
            }

            lock.lock()
            pending.append(InotifyDescriptorEvent(descriptor: watchDescriptor, kind: kind, name: ""))
            lock.unlock()
        }
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
        }

        let watch = DarwinWatch(descriptor: watchDescriptor, fileDescriptor: fileDescriptor, source: source)
        lock.lock()
        watches[watchDescriptor] = watch
        lock.unlock()
        source.resume()
        return watchDescriptor
        #else
        throw ServerWatcherError.unsupportedPlatform
        #endif
    }

    func removeWatch(_ descriptorToRemove: Int32) throws {
        #if os(Linux)
        let result = inotify_rm_watch(try inotifyDescriptor().rawValue, descriptorToRemove)
        guard result == 0 else {
            throw ServerWatcherError.systemCallFailed("inotify_rm_watch", errno: errno)
        }
        #elseif os(macOS)
        lock.lock()
        let watch = watches.removeValue(forKey: descriptorToRemove)
        pending.removeAll { $0.descriptor == descriptorToRemove }
        lock.unlock()
        watch?.source.cancel()
        #else
        throw ServerWatcherError.unsupportedPlatform
        #endif
    }

    func readEvents() throws -> [InotifyDescriptorEvent] {
        #if os(Linux)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let byteCount = Glibc.read(try inotifyDescriptor().rawValue, &buffer, buffer.count)
        if byteCount < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return []
            }
            throw ServerWatcherError.systemCallFailed("read", errno: errno)
        }
        guard byteCount > 0 else { return [] }

        var events: [InotifyDescriptorEvent] = []
        var offset = 0
        while offset + 16 <= byteCount {
            let watchDescriptor = Int32(bitPattern: UInt32(littleEndianBytes: buffer, offset: offset))
            let mask = UInt32(littleEndianBytes: buffer, offset: offset + 4)
            let nameLength = Int(UInt32(littleEndianBytes: buffer, offset: offset + 12))
            let nameStart = offset + 16
            let nameEnd = min(nameStart + nameLength, byteCount)
            let nameBytes = buffer[nameStart..<nameEnd].prefix { $0 != 0 }
            // Filenames are raw bytes on Linux; lossy decoding is intentional for event paths.
            // swiftlint:disable:next optional_data_string_conversion
            let name = String(decoding: nameBytes, as: UTF8.self)

            if let kind = ServerWatchEventKind(mask: mask) {
                events.append(InotifyDescriptorEvent(descriptor: watchDescriptor, kind: kind, name: name))
            }
            offset = nameStart + nameLength
        }
        return events
        #elseif os(macOS)
        lock.lock()
        defer { lock.unlock() }
        let events = pending
        pending.removeAll()
        return events
        #else
        throw ServerWatcherError.unsupportedPlatform
        #endif
    }
}

struct UnsupportedInotifyBackend: InotifyBackend {
    func addWatch(path: String) throws -> Int32 {
        throw ServerWatcherError.unsupportedPlatform
    }

    func removeWatch(_ descriptor: Int32) throws {
        throw ServerWatcherError.unsupportedPlatform
    }

    func readEvents() throws -> [InotifyDescriptorEvent] {
        throw ServerWatcherError.unsupportedPlatform
    }
}

private extension ServerWatchEventKind {
    #if os(Linux)
    init?(mask: UInt32) {
        if mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0 {
            self = .created
        } else if mask & UInt32(IN_DELETE | IN_MOVED_FROM | IN_DELETE_SELF) != 0 {
            self = .deleted
        } else if mask & UInt32(IN_MOVE_SELF) != 0 {
            self = .renamed
        } else if mask & UInt32(IN_MODIFY | IN_ATTRIB) != 0 {
            self = .modified
        } else {
            return nil
        }
    }
    #endif
}

private extension UInt32 {
    init(littleEndianBytes bytes: [UInt8], offset: Int) {
        self = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
