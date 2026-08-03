import AppKit

extension FileListViewController {
    /// True when this listing can show the destination: it is the displayed
    /// directory, or a directory below it that can be expanded into view.
    func canRevealDestination(_ destination: Location) -> Bool {
        guard let current = currentDirectoryLocation else { return false }
        return destination == current || FileDropValidator.isDescendant(destination, of: current)
    }

    /// The post-operation reveal every copy and move ends with: expand the
    /// destination when it is a collapsed folder row, select the results, and
    /// activate this pane. See `resources/docs/operation-result-reveal.md`.
    func revealOperationResults(_ results: [Location], destination: Location) {
        guard canRevealDestination(destination) else { return }
        let expandedLocation = destination == currentDirectoryLocation ? nil : destination
        refreshSelectingLocations(results, expandingTo: expandedLocation) { [weak self] in
            guard let self, self.canRevealDestination(destination) else { return }
            self.navigationDelegate?.fileListDidRequestPaneActivation(self)
        }
    }
}
