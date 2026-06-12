import Foundation

let daemon = Daemon()
do {
    try daemon.run(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("detours-server: \(error)\n".utf8))
    exit(1)
}
