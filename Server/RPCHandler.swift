import Foundation

enum ServerRPCError: Error, Equatable {
    case unsupportedCommand(String)
}

struct RPCHandler {
    private let fileOperations = FileOperations()

    func run() throws {
        // The Phase 2 skeleton starts the helper process and keeps stdin/stdout
        // reserved for length-prefixed RPC frames. Phase 3 wires concrete RPC
        // dispatch once the client RemoteFileProvider lands.
        while let line = readLine() {
            _ = try handle(command: line)
        }
    }

    func handle(command: String) throws -> String {
        switch command {
        case "ProtocolVersion":
            return "1"
        case "List":
            return try fileOperations.listPlaceholder()
        default:
            throw ServerRPCError.unsupportedCommand(command)
        }
    }
}
