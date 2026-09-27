import Foundation
import RemoteOperationSupport

extension UITestEnvironment {
    static func persistedRemoteHost() throws -> RemoteHost? {
        guard isEnabled, let target = realRemoteTarget else { return nil }
        guard let root = controlDirectory else { throw RemoteOperationStore.StoreError.unsafeRecord }
        let location = root.appendingPathComponent(".detours-remote-host.json")
        let kind: RemoteHostKind = realRemoteContext == "WINDOWS_TARGET" ? .windows : .unix
        if FileManager.default.fileExists(atPath: location.path) {
            let host = try JSONDecoder().decode(RemoteHost.self, from: Data(contentsOf: location))
            guard host.sshTarget == target, host.kind == kind else { throw OperationContractError.identityMismatch }
            return host
        }
        let host = RemoteHost(displayName: target, sshTarget: target, kind: kind)
        try JSONEncoder().encode(host).write(to: location, options: .atomic)
        return host
    }
}
