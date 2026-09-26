import DetoursProcess
import Foundation
import RemoteOperationSupport

enum RemoteTransferArchive {
    static func write(folder: URL, output: FileHandle,
                      progress: @escaping @Sendable (UInt64) throws -> Void) throws -> OperationManifest {
        let parent = try OperationDirectory(path: Data(folder.deletingLastPathComponent().path.utf8))
        let name = Data(folder.lastPathComponent.utf8)
        let manifest = try parent.manifest(name) { _ in try Task.checkCancellation() }
        guard manifest.entries.first?.observation.kind == .directory else { throw OperationFilesystemError.unsupported }
        let entries = try manifest.entries.map { entry -> SevenZipArchiveWriter.Entry in
            guard let relative = String(data: entry.relativePath, encoding: .utf8) else {
                throw OperationFilesystemError.invalidPath
            }
            let location = relative.isEmpty ? folder : folder.appendingPathComponent(relative)
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let mode = attributes[.posixPermissions] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { throw OperationFilesystemError.unsupported }
            let observation = entry.observation
            let type: UInt32
            switch observation.kind {
            case .file: type = 0o100000
            case .directory: type = 0o040000
            case .symbolicLink: type = 0o120000
            }
            return .init(name: relative.isEmpty ? "tree" : "tree/" + relative,
                input: nil, size: observation.byteCount, directory: observation.kind == .directory,
                mode: type | mode.uint32Value, modified: modified, linkTarget: observation.linkTarget,
                openInput: observation.kind == .file ? {
                    let directory = try OperationDirectory(path: Data(location.deletingLastPathComponent().path.utf8))
                    return try directory.openObservedFile(Data(location.lastPathComponent.utf8), expected: observation)
                } : nil)
        }
        try SevenZipArchiveWriter.create(entries: entries, output: output, password: nil, format: .zip) { bytes in
            try Task.checkCancellation()
            try progress(bytes)
        }
        try output.synchronize()
        guard try parent.manifest(name, progress: { _ in try Task.checkCancellation() }) == manifest else {
            throw OperationFilesystemError.identityChanged
        }
        return manifest
    }
}
