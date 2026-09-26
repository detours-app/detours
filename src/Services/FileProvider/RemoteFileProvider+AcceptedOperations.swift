import Foundation
import RemoteOperationSupport

extension RemoteFileProvider {
    func operationRequest(_ request: OperationRequest) async throws -> OperationReply {
        let chunks = try await rpcClient.send(.operation(request))
        guard chunks.count == 1, let payload = chunks.first else { throw OperationContractError.invalidReceipt }
        return try OperationReply.decode(payload)
    }

    func prepareAcceptedUpload(_ localURL: URL, identity: OperationRequestIdentity) async throws -> OperationReceipt {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw OperationContractError.invalidReceipt }
        if Int64(size) <= RemoteTransferChannel.rpcThresholdBytes {
            let contents = try Data(contentsOf: localURL)
            guard Int64(contents.count) <= RemoteTransferChannel.rpcThresholdBytes else { throw OperationContractError.invalidReceipt }
            guard case .receipt(let receipt) = try await operationRequest(.prepareUpload(identity: identity, contents: contents)) else {
                throw OperationContractError.invalidReceipt
            }
            return receipt
        }
        return try await transferChannel.prepareAcceptedUpload(source: localURL, identity: identity, rpcClient: rpcClient)
    }

    func operationPath(_ location: Location) async throws -> OperationLocation.Path {
        .unix(try remotePath(from: location).bytes)
    }

    func displayLocation(_ path: OperationLocation.Path) async throws -> Location {
        guard case .unix(let bytes) = path else { throw OperationContractError.identityMismatch }
        let remote = RemotePath(bytes: bytes)
        let location = Location.remote(hostID: hostID, path: remote.lossyDisplayString)
        rawPaths[location] = remote
        return location
    }
}

extension WindowsRemoteProvider {
    func prepareAcceptedUpload(_ localURL: URL, identity: OperationRequestIdentity) async throws -> OperationReceipt {
        try await prepareAcceptedUpload(localURL, identity: identity, sftpAvailable: true)
    }

    func operationPath(_ location: Location) async throws -> OperationLocation.Path {
        let path = try WindowsPath(location: location, hostID: hostID)
        guard let native = path.nativePath else { throw WindowsPathError.nativePathRequired(path.remotePath) }
        return .windows(native)
    }

    func displayLocation(_ path: OperationLocation.Path) async throws -> Location {
        guard case .windows(let native) = path else { throw OperationContractError.identityMismatch }
        return .remote(hostID: hostID, path: try WindowsPath.remotePath(fromNative: native))
    }
}
