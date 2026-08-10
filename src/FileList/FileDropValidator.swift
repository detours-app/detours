import Foundation

enum FileDropRejection: Equatable {
    case missingSource
    case missingDestination
    case destinationIsNotDirectory
    case destinationIsNotWritable
    case sourceEqualsDestination
    case sourceContainsDestination
    case sourceAlreadyInDestination
}

struct FileDropValidator {
    static func validate(
        sources: [Location],
        destination: Location?,
        destinationIsDirectory: Bool,
        destinationIsWritable: Bool,
        allowsEmptySources: Bool = false
    ) -> FileDropRejection? {
        if sources.isEmpty && !allowsEmptySources {
            return .missingSource
        }
        guard let destination else { return .missingDestination }
        guard destinationIsDirectory else { return .destinationIsNotDirectory }
        guard destinationIsWritable else { return .destinationIsNotWritable }

        for source in sources {
            if source == destination {
                return .sourceEqualsDestination
            }
            if isDescendant(destination, of: source) {
                return .sourceContainsDestination
            }
            if source.deletingLastPathComponent() == destination {
                return .sourceAlreadyInDestination
            }
        }
        return nil
    }

    static func isDescendant(_ location: Location, of ancestor: Location) -> Bool {
        switch (normalized(location), normalized(ancestor)) {
        case (.local(let locationURL), .local(let ancestorURL)):
            return path(locationURL.path, isDescendantOf: ancestorURL.path)
        case let (.remote(locationHost, locationPath), .remote(ancestorHost, ancestorPath)):
            return locationHost == ancestorHost
                && path(locationPath, isDescendantOf: ancestorPath)
        default:
            return false
        }
    }

    private static func normalized(_ location: Location) -> Location {
        switch location {
        case .local(let url):
            return .local(url.standardizedFileURL)
        case .remote(let hostID, let path):
            return .remote(
                hostID: hostID,
                path: Location.remoteFileURL(path).standardizedFileURL.path
            )
        }
    }

    private static func path(_ path: String, isDescendantOf ancestorPath: String) -> Bool {
        guard path != ancestorPath else { return false }
        let ancestorComponents = Location.remoteFileURL(ancestorPath).standardizedFileURL.pathComponents
        let pathComponents = Location.remoteFileURL(path).standardizedFileURL.pathComponents
        guard pathComponents.count > ancestorComponents.count else { return false }
        return pathComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }
}
