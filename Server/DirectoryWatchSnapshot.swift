import Foundation

enum DirectoryWatchSnapshot: Equatable {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    struct Entry: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
        let permissions: UInt64
    }

    case available(Identity, [String: Entry])
    case unavailable(String, Int)

    var identity: Identity? {
        guard case .available(let identity, _) = self else { return nil }
        return identity
    }

    static func capture(_ path: String) -> Self {
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: path)
            let identity = Identity(
                device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            )
            var entries: [String: Entry] = [:]
            for name in try manager.contentsOfDirectory(atPath: path) {
                do {
                    let child = (path as NSString).appendingPathComponent(name)
                    let values = try manager.attributesOfItem(atPath: child)
                    entries[name] = Entry(
                        inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                        size: (values[.size] as? NSNumber)?.uint64Value ?? 0,
                        modified: (values[.modificationDate] as? Date) ?? .distantPast,
                        permissions: (values[.posixPermissions] as? NSNumber)?.uint64Value ?? 0
                    )
                } catch {
                    guard FileOperations.isMissingFileError(error) else { throw error }
                }
            }
            return .available(identity, entries)
        } catch {
            let error = error as NSError
            return .unavailable(error.domain, error.code)
        }
    }
}
