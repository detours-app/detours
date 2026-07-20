import Foundation
import QualificationSupport

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("detours-qualification-guard: \(message)\n".utf8))
    exit(1)
}

private func value(after option: String, in arguments: [String]) -> String {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
        fail("missing \(option)")
    }
    return arguments[index + 1]
}

private let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: detours-qualification-guard <create|validate|remove> [options]")
}

let guardService = QualificationRunRootGuard()

do {
    switch command {
    case "create":
        let providerValue = value(after: "--provider", in: arguments)
        guard let provider = QualificationProvider(rawValue: providerValue) else {
            throw QualificationRunRootError.unsupportedProvider(providerValue)
        }
        let parent = URL(fileURLWithPath: value(after: "--parent", in: arguments), isDirectory: true)
        let descriptorPath = URL(fileURLWithPath: value(after: "--descriptor", in: arguments))
        let identifier: UUID
        if arguments.contains("--identifier") {
            let identifierValue = value(after: "--identifier", in: arguments)
            guard let parsed = UUID(uuidString: identifierValue) else {
                throw QualificationRunRootError.invalidIdentifier(identifierValue)
            }
            identifier = parsed
        } else {
            identifier = UUID()
        }
        let descriptor = try guardService.create(provider: provider, allowlistedParent: parent, identifier: identifier)
        try guardService.writeDescriptor(descriptor, to: descriptorPath)
        print(descriptor.rootPath)

    case "validate":
        let descriptorURL = URL(fileURLWithPath: value(after: "--descriptor", in: arguments))
        let candidateURL = URL(fileURLWithPath: value(after: "--path", in: arguments))
        let descriptor = try guardService.readDescriptor(at: descriptorURL)
        try guardService.validate(descriptor: descriptor, candidate: candidateURL)
        print(candidateURL.path)

    case "remove":
        let descriptorURL = URL(fileURLWithPath: value(after: "--descriptor", in: arguments))
        let descriptor = try guardService.readDescriptor(at: descriptorURL)
        try guardService.removeValidatedRoot(descriptor)
        print(descriptor.rootPath)

    default:
        fail("unknown command: \(command)")
    }
} catch {
    fail(error.localizedDescription)
}
