import Foundation

@MainActor
final class RemotePaneObservation {
    private let id = UUID()
    private var update: Task<Void, Never>?
    private var hostID: UUID?

    func view(_ hostID: UUID?) {
        guard self.hostID != hostID else { return }
        self.hostID = hostID
        let previous = update
        let id = id
        update = Task {
            await previous?.value
            await RemoteConnectionRegistry.shared.setPaneObservation(id, hostID: hostID)
        }
    }

    deinit {
        let previous = update
        let id = id
        Task {
            await previous?.value
            await RemoteConnectionRegistry.shared.setPaneObservation(id, hostID: nil)
        }
    }
}
