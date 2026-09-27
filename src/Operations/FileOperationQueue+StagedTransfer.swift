import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func prepareStagedTransfer(_ staged: URL, in stagingDirectory: URL, archiveFolders: Bool = true) throws
        -> (OperationContentProof, OperationContentProof?, RemoteOperationCoordinator.Work) {
        let directory = try OperationDirectory(path: Data(stagingDirectory.path.utf8))
        let observed = try directory.observe(Data(staged.lastPathComponent.utf8))
        if observed.kind == .file {
            let proof = try directory.proveFile(Data(staged.lastPathComponent.utf8), progress: { _ in try Task.checkCancellation() })
            guard let digest = proof.sha256 else { throw OperationFilesystemError.identityChanged }
            return (.init(byteCount: proof.byteCount, sha256: digest), nil, .upload(staged))
        }
        guard observed.kind == .directory else { throw OperationFilesystemError.unsupported }
        if !archiveFolders {
            let tree = try directory.manifest(Data(staged.lastPathComponent.utf8), progress: { _ in try Task.checkCancellation() })
            return (tree.proof, tree.proof, .upload(staged))
        }
        let workspace = try OperationWorkspace(parent: directory, id: .init(operation: UUID(), item: UUID()))
        let output = try workspace.createFile(named: Data("tree.zip".utf8))
        defer { try? output.close() }
        let tree = try RemoteTransferArchive.write(folder: staged, output: output, progress: { _ in try Task.checkCancellation() })
        let payload = try workspace.directory.proveFile(Data("tree.zip".utf8), progress: { _ in try Task.checkCancellation() })
        guard let digest = payload.sha256, let path = String(data: try workspace.directory.childPath(Data("tree.zip".utf8)),
                                                           encoding: .utf8) else { throw OperationFilesystemError.invalidPath }
        return (.init(byteCount: payload.byteCount, sha256: digest), tree.proof, .uploadTree(URL(fileURLWithPath: path)))
    }
}
