import Foundation

/// The split-view services a pane needs from its host. The pane layer talks to the host
/// only through this protocol; MainSplitViewController conforms and injects itself into
/// both panes when it loads, so no pane code depends on the concrete host type.
@MainActor
protocol PaneSplitCoordinating: AnyObject {
    func switchToOtherPane()
    func setActivePaneFromChild(_ pane: PaneViewController)
    func moveItems(_ items: [Location], toOtherPaneFrom pane: PaneViewController)
    func copyItems(_ items: [Location], toOtherPaneFrom pane: PaneViewController)
    func refreshPanes(matching directories: Set<URL>)
    func refreshPanes(matching locations: Set<Location>)
    func refreshPanes(matching locations: Set<Location>, preferredResultLocations: Set<Location>)
    func scheduleSaveSession()
    func retryRemoteConnection(for host: RemoteHost)
    func otherPane(from pane: PaneViewController) -> PaneViewController
}
