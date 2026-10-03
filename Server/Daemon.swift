import Foundation

struct Daemon {
    func run(arguments: [String]) throws {
        if arguments.contains("--transfer") {
            try TransferMode().run()
            return
        }

        try RPCHandler(operationHomeDirectory: try Self.operationHomeDirectory(in: arguments)).run()
    }

    /// `--operation-home <dir>` keeps the operation journal and trash under `<dir>` instead of
    /// the account's home; the app's UI tests use it to keep the helper inside their run root.
    static func operationHomeDirectory(in arguments: [String]) throws -> URL? {
        guard let index = arguments.firstIndex(of: "--operation-home") else { return nil }
        guard index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
            throw DaemonArgumentError.operationHomeRequiresAbsolutePath
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
}

enum DaemonArgumentError: Error {
    case operationHomeRequiresAbsolutePath
}
