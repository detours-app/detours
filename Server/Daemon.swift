import Foundation

struct Daemon {
    private let rpcHandler = RPCHandler()

    func run(arguments: [String]) throws {
        if arguments.contains("--transfer") {
            try TransferMode().run()
            return
        }

        try rpcHandler.run()
    }
}
