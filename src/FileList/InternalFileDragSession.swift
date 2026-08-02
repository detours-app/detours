import AppKit

extension NSPasteboard.PasteboardType {
    static let detoursInternalFileDrag = NSPasteboard.PasteboardType(
        "com.detours.internal-file-drag"
    )
}

/// Encodes a dragged item's location onto its own pasteboard item.
///
/// Local rows are recoverable from their file URL, but remote rows have no URL
/// representation, so each remote pasteboard item carries its location directly.
enum InternalFileDragPayload {
    static func encode(_ location: Location) -> String? {
        guard let data = try? JSONEncoder().encode(location) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String) -> Location? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Location.self, from: data)
    }
}

@MainActor
final class InternalFileDragSessionStore {
    static let shared = InternalFileDragSessionStore()

    private var locationsByToken: [UUID: [Location]] = [:]

    @discardableResult
    func begin(locations: [Location], on pasteboard: NSPasteboard) -> UUID? {
        guard !locations.isEmpty else { return nil }
        // Writers that already encode their own location own the pasteboard's
        // internal type; adding a token here would overwrite the first item.
        guard encodedLocations(on: pasteboard) == nil else { return nil }
        let token = UUID()
        locationsByToken[token] = locations
        pasteboard.addTypes([.detoursInternalFileDrag], owner: nil)
        guard pasteboard.setString(
            token.uuidString,
            forType: .detoursInternalFileDrag
        ) else {
            locationsByToken.removeValue(forKey: token)
            return nil
        }
        return token
    }

    func locations(on pasteboard: NSPasteboard) -> [Location]? {
        if let encoded = encodedLocations(on: pasteboard) {
            return encoded
        }
        guard let tokenString = pasteboard.string(forType: .detoursInternalFileDrag),
              let token = UUID(uuidString: tokenString) else {
            return nil
        }
        return locationsByToken[token]
    }

    func end(on pasteboard: NSPasteboard) {
        guard let tokenString = pasteboard.string(forType: .detoursInternalFileDrag),
              let token = UUID(uuidString: tokenString) else {
            return
        }
        locationsByToken.removeValue(forKey: token)
    }

    private func encodedLocations(on pasteboard: NSPasteboard) -> [Location]? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        let locations = items.compactMap { item -> Location? in
            guard let string = item.string(forType: .detoursInternalFileDrag) else { return nil }
            return InternalFileDragPayload.decode(string)
        }
        return locations.isEmpty ? nil : locations
    }
}
