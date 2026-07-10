import Foundation

/// Survives across retries of an interrupted remote copy.
///
/// `performQueuedRemoteAwareWork` retries a paused host's operation by re-invoking the whole work
/// closure. Without carrying the already-copied sources forward, the retry re-sends every item and
/// the server appends a numbered suffix to each one that already landed.
@MainActor
final class RemoteCopyResumeState {
    private(set) var remaining: [Location]
    private(set) var copied: [Location] = []

    init(items: [Location]) {
        remaining = items
    }

    var next: Location? { remaining.first }

    func recordCopied(_ locations: [Location]) {
        guard !remaining.isEmpty else { return }
        remaining.removeFirst()
        copied.append(contentsOf: locations)
    }
}
