import AppKit

extension NSPasteboard.PasteboardType {
    static let detoursInternalFileDrag = NSPasteboard.PasteboardType(
        "com.detours.internal-file-drag"
    )
}

@MainActor
final class InternalFileDragSessionStore {
    static let shared = InternalFileDragSessionStore()

    private var locationsByToken: [UUID: [Location]] = [:]

    @discardableResult
    func begin(locations: [Location], on pasteboard: NSPasteboard) -> UUID? {
        guard !locations.isEmpty else { return nil }
        let token = UUID()
        locationsByToken[token] = locations
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
}
