import Foundation
import RemoteOperationSupport

extension PowerShellChannel {
    func runOperation(_ arguments: WindowsOperationArguments, operation: String) async throws -> Data {
        let script = try PowerShellScript(source: WindowsOperationScripts.protocolScript, arguments: arguments)
        let identity: OperationRequestIdentity?
        switch arguments.request {
        case .sealIngress(let value): identity = value
        case .shared(let request):
            switch request {
            case .status, .cancel: return try await runIndependent(script, operation: operation)
            case .prepareUpload(let value, _), .prepareCopy(let value), .prepareArchive(let value, _), .execute(let value):
                identity = value
            default: identity = nil
            }
        default: identity = nil
        }
        guard let identity else { return try await run(script, operation: operation) }
        _ = try await readyForAuxiliaryRequest()
        let progress = RemoteMeasuredProgress()
        let status = try PowerShellScript(source: WindowsOperationScripts.protocolScript,
            arguments: WindowsOperationArguments(.status(identity)))
        let monitor = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    let response = try await self.runIndependent(status, operation: "OperationProgress")
                    guard case .status(let snapshot) = try OperationReply.decode(response),
                          snapshot.id == identity.id, snapshot.account == identity.account,
                          snapshot.epoch == identity.epoch, snapshot.intentDigest == identity.intentDigest else {
                        throw PowerShellChannelError.invalidResponse("Unverified operation progress")
                    }
                    if let measured = snapshot.receipt?.measuredBytes { progress.record(measured) }
                }
            } catch {
                if !Task.isCancelled { progress.fail(error) }
            }
        }
        defer { monitor.cancel() }
        do { return try await run(script, operation: operation, progress: progress) } catch {
            try Task.checkCancellation()
            try progress.check()
            throw error
        }
    }
}
