import Foundation

@MainActor
struct RemoteHostsSection {
    var store: RemoteHostStore = .shared

    func items() -> [RemoteHost] {
        store.hosts.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
