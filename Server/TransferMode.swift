import Foundation

struct TransferMode {
    func run() throws {
        // Transfer frames are length-prefixed raw byte streams. The concrete
        // streaming loop lands with server file operations; this entry point is
        // intentionally present now so the client can invoke helper transfer mode.
        FileHandle.standardOutput.write(Data())
    }
}
