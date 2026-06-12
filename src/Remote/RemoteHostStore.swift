import Foundation

@MainActor
final class RemoteHostStore {
    static let shared = RemoteHostStore()

    static let remoteHostsDidChange = Notification.Name("RemoteHostStore.remoteHostsDidChange")

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var hosts: [RemoteHost] {
        didSet {
            save()
            NotificationCenter.default.post(name: Self.remoteHostsDidChange, object: self)
        }
    }

    init(defaults: UserDefaults = .standard, key: String = "Detours.RemoteHosts") {
        self.defaults = defaults
        self.key = key
        let loadedHosts = Self.loadHosts(from: defaults, key: key, decoder: decoder)
        self.hosts = Self.deduplicatedHosts(loadedHosts)
        if hosts.count != loadedHosts.count {
            save()
        }
    }

    @discardableResult
    func add(displayName: String, sshTarget: String) -> RemoteHost {
        let host = RemoteHost(displayName: displayName, sshTarget: sshTarget)
        hosts.append(host)
        return host
    }

    @discardableResult
    func upsert(_ host: RemoteHost) -> RemoteHost {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
            return host
        } else if let index = hosts.firstIndex(where: { Self.normalizedTarget($0.sshTarget) == Self.normalizedTarget(host.sshTarget) }) {
            let existing = hosts[index]
            let updated = RemoteHost(
                id: existing.id,
                displayName: host.displayName,
                sshTarget: host.sshTarget,
                knownHostKeyFingerprint: host.knownHostKeyFingerprint ?? existing.knownHostKeyFingerprint,
                lastConnected: host.lastConnected ?? existing.lastConnected
            )
            hosts[index] = updated
            return updated
        } else {
            hosts.append(host)
            return host
        }
    }

    func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
    }

    func host(id: UUID) -> RemoteHost? {
        hosts.first { $0.id == id }
    }

    func markConnected(id: UUID, at date: Date = Date()) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastConnected = date
    }

    func updateFingerprint(id: UUID, fingerprint: String) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].knownHostKeyFingerprint = fingerprint
    }

    func replaceAll(_ hosts: [RemoteHost]) {
        self.hosts = hosts
    }

    private func save() {
        do {
            let data = try encoder.encode(hosts)
            defaults.set(data, forKey: key)
        } catch {
            assertionFailure("Failed to encode remote hosts: \(error)")
        }
    }

    private static func loadHosts(from defaults: UserDefaults, key: String, decoder: JSONDecoder) -> [RemoteHost] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? decoder.decode([RemoteHost].self, from: data)) ?? []
    }

    private static func deduplicatedHosts(_ hosts: [RemoteHost]) -> [RemoteHost] {
        var result: [RemoteHost] = []
        var indexesByTarget: [String: Int] = [:]
        for host in hosts {
            let target = normalizedTarget(host.sshTarget)
            guard !target.isEmpty else { continue }
            if let index = indexesByTarget[target] {
                let existing = result[index]
                result[index] = RemoteHost(
                    id: existing.id,
                    displayName: host.displayName,
                    sshTarget: host.sshTarget,
                    knownHostKeyFingerprint: host.knownHostKeyFingerprint ?? existing.knownHostKeyFingerprint,
                    lastConnected: host.lastConnected ?? existing.lastConnected
                )
            } else {
                indexesByTarget[target] = result.count
                result.append(host)
            }
        }
        return result
    }

    private static func normalizedTarget(_ target: String) -> String {
        target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
