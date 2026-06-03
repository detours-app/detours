import Foundation

#if os(Linux)
import Glibc
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

enum ServerWatcherError: Error, Equatable, Sendable {
    case unsupportedPlatform
    case inotifyLimitExceeded(command: String)
    case systemCallFailed(String, errno: Int32)
    case unknownWatch(UUID)
}

protocol InotifyBackend {
    func addWatch(path: String) throws -> Int32
    func removeWatch(_ descriptor: Int32) throws
}

final class Watcher {
    static let inotifyLimitCommand = "sudo sysctl fs.inotify.max_user_watches=524288"

    private let backend: InotifyBackend
    private var watchesByToken: [UUID: WatchRegistration] = [:]
    private var tokenByDescriptor: [Int32: UUID] = [:]

    #if os(Linux)
    init(backend: InotifyBackend = SystemInotifyBackend()) {
        self.backend = backend
    }
    #else
    init(backend: InotifyBackend = UnsupportedInotifyBackend()) {
        self.backend = backend
    }
    #endif

    var visibleWatchCount: Int {
        watchesByToken.count
    }

    func watchVisibleDirectory(_ path: String, token: UUID) throws {
        if watchesByToken[token] != nil {
            try unwatch(token)
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
        guard let registration = watchesByToken.removeValue(forKey: token) else {
            throw ServerWatcherError.unknownWatch(token)
        }
        tokenByDescriptor.removeValue(forKey: registration.descriptor)
        try backend.removeWatch(registration.descriptor)
    }

    func registration(for token: UUID) -> WatchRegistration? {
        watchesByToken[token]
    }

    func token(for descriptor: Int32) -> UUID? {
        tokenByDescriptor[descriptor]
    }
}

struct WatchRegistration: Equatable, Sendable {
    let token: UUID
    let path: String
    let descriptor: Int32
}

struct SystemInotifyBackend: InotifyBackend {
    private final class FileDescriptor {
        let rawValue: Int32

        init() throws {
            #if os(Linux)
            rawValue = inotify_init1(IN_CLOEXEC | IN_NONBLOCK)
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

    private let descriptor: FileDescriptor

    init() {
        descriptor = try! FileDescriptor()
    }

    func addWatch(path: String) throws -> Int32 {
        #if os(Linux)
        let mask = UInt32(IN_CREATE | IN_MODIFY | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB)
        let watchDescriptor = path.withCString { pathPointer in
            inotify_add_watch(descriptor.rawValue, pathPointer, mask)
        }
        guard watchDescriptor >= 0 else {
            throw ServerWatcherError.systemCallFailed("inotify_add_watch", errno: errno)
        }
        return watchDescriptor
        #else
        throw ServerWatcherError.unsupportedPlatform
        #endif
    }

    func removeWatch(_ descriptorToRemove: Int32) throws {
        #if os(Linux)
        let result = inotify_rm_watch(descriptor.rawValue, descriptorToRemove)
        guard result == 0 else {
            throw ServerWatcherError.systemCallFailed("inotify_rm_watch", errno: errno)
        }
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
}
