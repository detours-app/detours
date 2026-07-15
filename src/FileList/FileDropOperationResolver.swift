import AppKit

enum FileDropOperation: Equatable {
    case copy
    case move

    var appKitOperation: NSDragOperation {
        switch self {
        case .copy:
            return .copy
        case .move:
            return .move
        }
    }
}

struct FileDropOperationResolver {
    typealias LocalVolumeIdentifier = (URL) -> AnyHashable?

    static func resolve(
        sources: [Location],
        destination: Location,
        modifiers: NSEvent.ModifierFlags,
        localVolumeIdentifier: LocalVolumeIdentifier = defaultLocalVolumeIdentifier
    ) -> FileDropOperation {
        if modifiers.contains(.option) {
            return .copy
        }
        if modifiers.contains(.command) {
            return .move
        }

        let sharesEveryBoundary = sources.allSatisfy { source in
            sharesBoundary(
                source,
                destination,
                localVolumeIdentifier: localVolumeIdentifier
            )
        }
        return sharesEveryBoundary ? .move : .copy
    }

    private static func sharesBoundary(
        _ source: Location,
        _ destination: Location,
        localVolumeIdentifier: LocalVolumeIdentifier
    ) -> Bool {
        switch (source, destination) {
        case let (.remote(sourceHost, _), .remote(destinationHost, _)):
            return sourceHost == destinationHost
        case let (.local(sourceURL), .local(destinationURL)):
            guard let sourceVolume = localVolumeIdentifier(sourceURL),
                  let destinationVolume = localVolumeIdentifier(destinationURL) else {
                return false
            }
            return sourceVolume == destinationVolume
        default:
            return false
        }
    }

    private static func defaultLocalVolumeIdentifier(for url: URL) -> AnyHashable? {
        let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
        return values?.volumeIdentifier as? AnyHashable
    }
}
